# NTFS `$ATTRIBUTE_LIST` C 구현 분석

## 분석 범위

`HEAD~14..HEAD`의 14개 커밋을 분석했다. 대상은 NTFS의 attribute
list(ALE, `struct attr_list_entry`)를 검색 컨텍스트가 참조하고 갱신하는
경로이며, 변경 파일은 다음과 같다.

| 파일 | 역할 |
| --- | --- |
| `fs/ntfs/attrib.c`, `attrib.h` | 검색 컨텍스트 locator, ALE 검색, extent 이동 및 mapping-pair 갱신 |
| `fs/ntfs/attrlist.c` | ALE 삽입/삭제와 `$ATTRIBUTE_LIST` 영속화 |
| `fs/ntfs/inode.c`, `inode.h` | inode별 락/세대 초기화 및 목록 생성ㆍ제거 경로 |
| `fs/ntfs/index.c` | attr-list 경유 검색 여부 판별 |

## 브랜치의 목적

이 브랜치의 핵심 목적은 `struct ntfs_attr_search_ctx`가 보관하던
`ctx->al_entry` raw pointer를 제거하는 것이다.

attribute list는 삽입ㆍ삭제 시 새 버퍼를 할당해 `base_ni->attr_list`와
교체한다. 따라서 search context에 보관된 기존 ALE 포인터는 버퍼 교체 뒤
댕글링 포인터가 된다. 특히 extent를 이동하거나 non-resident attribute의
mapping pairs를 갱신하는 쓰기 경로에서, 이 포인터를 사용하면 잘못된 ALE를
갱신하거나 해제된 메모리를 참조할 수 있다.

단순히 attribute list 락을 search context의 전체 수명 동안 잡는 방식은
사용하지 않는다. 해당 방식은 기존의 `runlist.lock` 중심 경로와 역순 락
획득을 만들고, attribute lookup을 사용하는 광범위한 호출자에게 락 상태를
전파해야 한다. 대신 짧은 in-memory 임계 구역과 재검증 가능한 locator를
사용한다.

## 최종 설계

### inode 상태와 락

`struct ntfs_inode`에 다음 상태를 추가했다.

```c
struct rw_semaphore attr_list_lock;
struct mutex attr_list_persist_lock;
u32 attr_list_gen;
```

- `attr_list_lock`은 `attr_list`, `attr_list_size`, `attr_list_gen` 및
  in-memory ALE의 검색ㆍspliceㆍ수정을 보호한다.
- `attr_list_gen`은 버퍼 교체와 lookup/정렬에 보이는 ALE 변경마다 증가한다.
  단순한 disk flush는 세대를 바꾸지 않는다.
- `attr_list_persist_lock`은 새 버퍼를 publish한 뒤
  `ntfs_attrlist_update()`로 영속화하고 실패 시 rollback하는 전체 소유권
  구간을 직렬화한다.

실질적인 락 순서는 다음과 같다.

```text
inode_lock/i_rwsem -> mrec_lock -> runlist.lock -> attr_list_lock
```

`attr_list_lock`을 잡은 상태에서 `ntfs_attrlist_update()`를 호출하면 안 된다.
영속화는 truncate/resize/non-resident 변환을 거쳐 `runlist.lock`을 잡을 수
있기 때문이다. 삽입과 삭제는 write lock 아래에서 in-memory 목록만
교체하고 lock을 놓은 뒤 영속화한다.

### search context locator

raw pointer 대신 `ntfs_attr_search_ctx`에 세 종류의 상태를 저장한다.

| 상태 | 용도 | 무효화 시 처리 |
| --- | --- | --- |
| `al_cursor` | ALE 열거 재개 위치 | generation 불일치이면 목록 처음부터 재시작 |
| `al_insert` | `-ENOENT` 시 insert-before 위치 | generation 불일치 또는 invalid이면 lookup 재실행 |
| `al_exact` | 쓰기 경로에서 수정/삭제할 정확한 ALE 식별 | offset fast path 후 완전 키로 write lock 아래 재검색 |
| `used_attrlist` | 검색이 attr-list를 경유했는지 | raw pointer 존재 여부를 대체 |

`al_exact`의 키는 `type`, 이름, `lowest_vcn`, `mft_reference`,
`instance`를 복사해 보관한다. 따라서 MFT record가 compact되거나 현재
`ctx->attr` 슬롯이 다른 attribute로 바뀐 뒤에도 대상 ALE의 identity는
유지된다.

`al_insert`는 offset과 generation만 보관한다. 삽입 지점은 정확한 객체
identity가 아니라 정렬된 목록의 위치이므로, stale하면 안전하게 lookup을
다시 수행한다.

## 핵심 구현 흐름

### 읽기: `ntfs_external_attr_find()`

1. `attr_list_lock` read lock 아래에서 `al_cursor`를 generation과 범위로
   검증한다.
2. 목록을 순회하면서 성공 시 `al_exact`를 캡처하고, 실패 시
   `al_insert`를 캡처한다.
3. 같은 type/name의 non-resident ALE에서 `ale->lowest_vcn`이 목표 VCN보다
   커지면 즉시 not-found로 처리한다. 이 지점이 올바른 삽입 지점이며,
   계속 검색하면 extent 정렬이 깨질 수 있다.
4. lock을 해제한 뒤 필요한 extent MFT record를 map하고 attribute record를
   찾는다.

모든 성공ㆍ오류ㆍnot-found 경로에서 read lock을 해제하도록 정리했다.

### 삽입/삭제: `ntfs_attrlist_entry_add()` / `ntfs_attrlist_entry_rm()`

두 함수는 공통적으로 다음 transaction을 따른다.

1. `attr_list_persist_lock`을 획득한다.
2. `attr_list_lock` write lock 아래에서 locator를 generation으로 검증하거나
   `al_exact` 키로 재검색한다.
3. 새 attribute-list 버퍼를 만들고 publish하며 `attr_list_gen`을 증가시킨다.
4. write lock을 해제한다.
5. `ntfs_attrlist_update()`로 목록을 디스크에 반영한다.
6. 성공하면 이전 버퍼를 free한다. 실패하면 현재 publish된 버퍼가 자기
   버퍼인지 확인한 뒤에만 이전 버퍼로 rollback하고 세대를 다시 증가시킨다.

영속화 중 다른 mutation이 새 버퍼를 publish하면 첫 mutation의 rollback이
그 새 상태를 덮어쓰거나 그 버퍼를 double-free할 수 있었다. persist mutex가
이 old/new 버퍼의 소유권을 영속화 완료 또는 rollback까지 유지한다.

### attribute 이동: `ntfs_attr_record_move_to()`

source attribute record를 삭제하면 MFT record compaction으로
`ctx->attr`가 가리키던 위치에는 다른 attribute가 들어갈 수 있다. 따라서
이동 후 `ctx->attr`에서 키를 다시 추출하지 않는다. lookup 시점에 저장한
`al_exact` 키로 대상 ALE를 다시 찾아 `mft_reference`와 `instance`만
갱신한다.

### mapping-pair 갱신: `__ntfs_attr_update_mapping_pairs()`

extent의 `lowest_vcn`과 ALE의 `lowest_vcn`은 함께 갱신되어야 한다.

- 먼저 write lock 아래에서 현재 attribute record의 **기존**
  `lowest_vcn`으로 ALE를 찾는다. attr record를 먼저 바꾸면 ctx 기반
  lookup의 키가 달라져 ALE를 찾을 수 없다.
- ALE의 `lowest_vcn`을 갱신하고 generation을 증가시킨다.
- 갱신한 ALE의 offset과 새 generation으로 `al_cursor` 및 `al_exact`를
  refresh한다. 다음 lookup이 오래된 cursor 때문에 목록 처음 또는 같은
  extent로 되돌아가지 않게 한다.
- 모든 extent의 in-memory ALE 및 mapping-pair record 갱신이 끝난 뒤,
  attr-list를 한 번만 영속화한다.

extent마다 영속화하면 그 과정에서 현재 MFT record가 이동할 수 있어
`ctx->attr`가 stale해진다. 또한 다음 mapping-pair fragment의 시작 VCN인
`stop_vcn`을 lookup VCN으로 재사용하면 lookup의 extent-normalization과
충돌해 이전 extent를 다시 선택할 수 있다. 최종 구현은 영속화를 루프
밖으로 미뤄 이 두 문제를 피한다.

## 커밋 진행과 해결한 결함

초기 4개 커밋은 locator plumbing, in-memory mutation과 persistence 분리,
generation 추적, 이동 경로 재검색을 도입했다. 이후 커밋은 설계가 드러낸
경계 조건을 수정했다.

| 커밋 | 보완 내용 |
| --- | --- |
| `70dfe6f7ceef` | read-lock leak, 삽입 rollback double-free, invalid insert anchor 사용 수정 |
| `4e83673b833d` | ALE lookup 전에 attr record의 `lowest_vcn`을 바꾸던 순서 오류 수정 |
| `e44e20b3caf3` | VCN 정렬 순서를 넘긴 탐색을 중단해 out-of-order ALE 삽입 방지 |
| `a3101551ce0d` | `ntfs_attr_position()`의 성공 `-ENOENT` 경로에서 exact locator 보충 |
| `a1f1720e1bd0` | publish/persist/rollback 수명을 `attr_list_persist_lock`으로 직렬화 |
| `ec9083ff965f` | record compaction 후 ctx-derived key 대신 immutable exact key 사용 |
| `d84be3e0a9a5` | ALE 수정 뒤 cursor generation/offset refresh |
| `0229f3257c75`, `ec3a1c5fcfa7` | mapping-pair 갱신 중 record relocation 및 VCN 재선택 문제를 피하도록 persistence 지연 |

## 결론

현재 브랜치는 단순한 attr-list 락 추가가 아니라, `$ATTRIBUTE_LIST`의
가변 버퍼 수명과 search context의 장기 수명을 분리하는 안정성 작업이다.
검색은 짧은 read-side 보호와 재시작 가능한 위치 정보를 사용하고, 쓰기는
immutable identity로 ALE를 재검증한다. mutation과 disk persistence는
분리하되 persist mutex로 rollback 소유권을 직렬화한다. 그 결과 extent
이동, sparse-file hole 쓰기, mapping-pair 갱신 및 attribute-list
생성/제거에서 raw-pointer use-after-free, 정렬 훼손, stale cursor,
deadlock, rollback 경쟁을 방지하는 것이 이 브랜치의 최종 목적이다.
