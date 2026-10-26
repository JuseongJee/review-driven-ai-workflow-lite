#!/usr/bin/env bash
# fr_relations.sh — FR 관계(의존·시리즈) 판정 엔진 (SSOT).
#
# items/ 상세 파일의 `- depends-on:` · `- series:` · `- relates:` 필드를 읽어 FR 별로
# "착수 가능 / 대기 / 확인 필요 / 오류" 를 판정한다. 판정 로직은 이 스크립트에만 둔다.
# skill 산문(`/fr list`·autopilot·`/fr batch`)은 이 스크립트를 호출해 출력을 표시만 한다.
#
# 서브커맨드:
#   readiness   --root <ROOT>                     활성 FR 1건당 `<stem><TAB><판정>`
#   validate    --root <ROOT>                     위반 1건당 `<종류><TAB><stem><TAB><설명>`
#   batch-draft --root <ROOT> --slugs "<s> <s>"   `<short-title><TAB><분류><TAB><값>`
#   auto-pick   --root <ROOT>                     첫 줄 select/queue-empty/queue-blocked/unavailable
#
# 판정 값: ready / waiting:<stem>,<stem> / check:<stem>,<stem> / error:<사유>
#          우선순위는 error > waiting > check > ready 이고 하나만 낸다.
#          error 사유는 parse:<필드명> / dangling:<csv> / series:<name> / cycle 이다.
#
# 종료 코드:
#   readiness    0 정상 / 2 실행 불가
#   validate     0 위반 없음(priority-drift 만 있으면 0) / 1 위반 / 2 실행 불가
#   batch-draft  0 정상 / 1 관계 오류 있음 / 2 실행 불가(slug 미해결 포함)
#   auto-pick    0 정상 / 2 unavailable
#
# 데이터 원천의 권위:
#   - 관계 필드·status 의 권위는 items/ 상세 파일이다.
#   - priority 의 권위는 FUTURE_REQUESTS.md 인덱스 컬럼이다 (change spec D9).
#   - 인덱스를 읽는 것은 `validate` 와 `auto-pick` 뿐이다. `readiness` 는 읽지 않는다 —
#     인덱스가 깨져도 목록 판정이 막히지 않아야 한다.
#   - 인덱스 구조가 손상되면(필수 헤더 부재·데이터 행 셀 수 부족·우선순위 셀 형식 오류)
#     그 행을 건너뛰지 않고 rc=2 로 끝낸다. 건너뛰면 그 FR 의 priority 가 사라져
#     auto-pick 이 다른 FR 을 고른다.
#
# 검사 범위:
#   - `readiness` 는 활성 FR 만 출력한다.
#   - `validate` 의 관계 검사(parse·dangling·series·cycle)는 전체 items 가 대상이다.
#     비활성 FR 만으로 된 시리즈의 번호 오류·없는 참조도 검출해야 한다.
#   - `validate` 의 인덱스 사본 대조(index-column·summary-prefix·priority-drift)는
#     실제 인덱스 행이 있는 FR 에만 적용한다.
#
# 출력 버퍼링: 네 서브커맨드 모두 계산이 전부 끝난 뒤 결과를 한 번에 낸다. 계산 도중
# stdout 에 흘려 쓰면 중간 실패 때 부분 결과가 새어 나간다. 실패는 조기 반환으로
# 처리하고 그때까지 쌓인 버퍼를 버린다.
#
# `auto-pick` 실행 순서 고정: ① 상세 파싱 → ② 판정 계산 → ③ 인덱스 읽기(priority)
# → ④ 선택 → ⑤ 출력. 이 순서라야 "인덱스가 깨진 입력" 이 판정 결과가 이미 만들어진
# 뒤 실패하는 경로가 되고, 부분 결과 누출을 fixture 로 검증할 수 있다.
#
# bash 3.2 호환: 연관배열(declare -A)을 쓰지 않는다. 조회는 stem 을 변수명으로 바꾼
# 동적 변수(`mput`/`mget`)로 한다 — items 325개에서 문자열 누적 + `${acc#*key=}` 추출은
# 실측 68초였다 (bash 의 `#` 접두 제거가 문자열 길이에 제곱으로 든다). 순환 탐지는
# `batch/batch_manifest.sh` 의 문자열 Kahn 을 옮긴 것이다.
#
# 동적 변수는 `eval` 을 쓰므로 키가 곧 코드다. 두 층으로 막는다.
#   ① 정책 층 — 외부에서 들어오는 stem(파일명·depends-on·relates 토큰·인덱스 제목·slug)이
#      `YYYY-MM-DD-<slug>` 형식인지 `valid_stem` 으로 본다. 벗어나면 그 입력을 버리고
#      진단으로 돌린다. 관계 필드 토큰만은 버리지 않고 그 FR 을 `error:parse:<필드명>` 으로
#      만든다 — 조용히 무시하면 의존이 사라져 착수 불가 FR 이 ready 로 보인다.
#   ② 구조 층 — `map_guard` 가 eval 직전에 맵 이름과 키가 `[A-Za-z0-9_]+` 인지 다시 본다.
#      정책 층을 지나친 값도 여기서 멈추고 rc=2(실행 불가)로 끝난다.
#
# awk→셸 필드 구분자는 `\034`(ASCII FS)를 쓴다. 탭이나 `\x01` 은 macOS Bash 3.2.57 의
# `read` 에서 IFS 공백류 축약 규칙에 걸리거나 필드가 분리되지 않는 결함이 실측됐다
# (`check_fr_index_detail_consistency.sh` 주석과 같은 이유).
#
# 인덱스 파싱은 헤더 기준 위치 해석이다. `## 인덱스` 아래 첫 `|` 행을 헤더로 삼아 컬럼
# 이름으로 위치를 찾고, 데이터 행은 앞에서 2개·뒤에서 N-3 개를 세고 남은 가운데를 요약으로
# 본다. 요약 셀에 이스케이프되지 않은 `|` 가 실제로 있기 때문이다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- 인자 파싱

CMD="${1:-}"
[ "$#" -gt 0 ] && shift

ROOT=""
SLUGS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      case "${2-}" in
        ""|-?*) echo "fr_relations.sh: --root 에 값이 없습니다." >&2; exit 2 ;;
      esac
      ROOT="$2"; shift 2 ;;
    --slugs)
      case "${2-}" in
        "") echo "fr_relations.sh: --slugs 에 값이 없습니다." >&2; exit 2 ;;
      esac
      SLUGS="$2"; shift 2 ;;
    *) echo "fr_relations.sh: 알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ROOT" ] || ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

INDEX_FILE="${ROOT}/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
ITEMS_DIR="${ROOT}/rd-workflow-workspace/backlog/items"

ERR_REASON=""
ERR_ACTION="fr_relations.sh validate --root . 로 원인 확인"

# ---------------------------------------------------------------- 맵 (bash 3.2)

# 키(stem·series name)는 `[a-z0-9-]` 와 날짜만 쓰므로 `-` 를 `_` 로 바꾸면 변수명이 된다.
# items 파일명에 `_` 는 쓰지 않으므로 이 치환은 단사(injective)다.
MV=""
# eval 직전 가드. 맵 이름과 키가 변수명 charset 을 벗어나면 eval 에 셸 문법이 섞인다.
# 정책 층(valid_stem 검증)을 지나쳐 들어온 값도 여기서 멈춘다. 실패는 내부 오류이므로
# MAP_ERR 에 표시하고 호출자가 rc=2(실행 불가) 경로로 보낸다 — 조용히 넘기지 않는다.
MAP_ERR=0
map_guard() { # map_guard <맵이름> <변환된 키>
  case "$1" in ""|*[!A-Za-z0-9_]*) ;; *)
    case "$2" in ""|*[!A-Za-z0-9_]*) ;; *) return 0 ;; esac ;;
  esac
  MAP_ERR=1
  ERR_REASON="내부 오류: 맵 이름·키에 허용되지 않는 문자 (map=${1}, key=${2})"
  return 1
}
mput() { # mput <맵이름> <키> <값>
  local kk="${2//-/_}"
  map_guard "$1" "$kk" || return 1
  eval "M_${1}_${kk}=\$3"
}
mget() { # mget <맵이름> <키> — 결과는 MV. 없으면 "-"
  local kk="${2//-/_}"
  if ! map_guard "$1" "$kk"; then MV="-"; return 1; fi
  eval "MV=\${M_${1}_${kk}-}"
  [ -n "$MV" ] || MV="-"
}

# valid_stem <문자열> — FR stem 형식 `YYYY-MM-DD-<slug>` 인지 본다.
# slug charset 은 `[a-z0-9-]+` 이며 batch_manifest.sh 의 resolve-slug 규칙과 같다.
valid_stem() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*) ;;
    *) return 1 ;;
  esac
  case "${1:11}" in
    ""|*[!a-z0-9-]*) return 1 ;;
  esac
  return 0
}

# short_title <stem> — stem 앞 10자(날짜)와 이어지는 `-` 를 뗀다.
short_title() { printf '%s' "${1:11}"; }

# split_csv <csv> — 쉼표 목록을 SPLIT_OUT 에 공백 구분으로 넣는다 (서브셸·tr 없이).
SPLIT_OUT=""
split_csv() {
  local rest="$1" one
  SPLIT_OUT=""
  [ "$rest" = "-" ] && return 0
  while [ -n "$rest" ]; do
    one="${rest%%,*}"
    if [ "$one" = "$rest" ]; then rest=""; else rest="${rest#*,}"; fi
    [ -n "$one" ] && [ "$one" != "-" ] || continue
    SPLIT_OUT="${SPLIT_OUT} ${one}"
  done
}

# ---------------------------------------------------------------- ① 상세 파싱
# 맵: ST(status) PRI(상세 priority) DEP(csv) REL(csv) SRAW(series 원문)
#     EX(존재) SNAME SN SM BADFMT(series 형식 오류)

ALL_STEMS=""
ACTIVE_STEMS=""
BAD_ITEM_NAMES=""

parse_items() {
  if [ ! -d "$ITEMS_DIR" ]; then
    ERR_REASON="items 디렉터리 없음: ${ITEMS_DIR}"
    return 1
  fi
  local files=() out rc stem st pri dep ser rel
  files=( "$ITEMS_DIR"/*.md )
  if [ ! -e "${files[0]}" ]; then
    return 0
  fi
  out="$(awk '
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function nosp(s) { gsub(/[ \t\r]/, "", s); return s }
    function val(line) { return trim(substr(line, index(line, ":") + 1)) }
    function flush() {
      if (fname == "") return
      printf "%s\034%s\034%s\034%s\034%s\034%s\n", fname,
        (status == "" ? "-" : status), (pri == "" ? "-" : pri),
        (dep == "" ? "-" : dep), (ser == "" ? "-" : ser), (rel == "" ? "-" : rel)
    }
    FNR == 1 {
      flush()
      fname = FILENAME; sub(/.*\//, "", fname); sub(/\.md$/, "", fname)
      status = ""; pri = ""; dep = ""; ser = ""; rel = ""
    }
    /^- status:/     { if (status == "") status = nosp(val($0)); next }
    /^- priority:/   { if (pri    == "") pri    = nosp(val($0)); next }
    /^- depends-on:/ { if (dep    == "") dep    = nosp(val($0)); next }
    /^- series:/     { if (ser    == "") ser    = nosp(val($0)); next }
    /^- relates:/    { if (rel    == "") rel    = nosp(val($0)); next }
    END { flush() }
  ' "${files[@]}" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    ERR_REASON="items 파싱 실행 오류 (awk rc=${rc}): ${out}"
    return 1
  fi
  while IFS=$'\034' read -r stem st pri dep ser rel; do
    [ -n "$stem" ] || continue
    if ! valid_stem "$stem"; then
      # 형식을 벗어난 파일명은 판정 대상에서 제외하고 validate 가 위반으로 보고한다.
      BAD_ITEM_NAMES="${BAD_ITEM_NAMES}${stem}
"
      continue
    fi
    ALL_STEMS="$ALL_STEMS $stem"
    mput EX "$stem" 1
    mput ST "$stem" "$st"
    mput PRI "$stem" "$pri"
    mput DEP "$stem" "$dep"
    mput REL "$stem" "$rel"
    mput SRAW "$stem" "$ser"
    case "$st" in
      done|dropped|parked) ;;
      *) ACTIVE_STEMS="$ACTIVE_STEMS $stem" ;;
    esac
  done <<< "$out"
  return 0
}

# ---------------------------------------------------------------- ② 시리즈 구성

SERIES_NAMES=""

build_series() {
  local stem raw name rest n m
  for stem in $ALL_STEMS; do
    mget SRAW "$stem"; raw="$MV"
    [ "$raw" = "-" ] && continue
    case "$raw" in *"#"*) ;; *) mput BADFMT "$stem" 1; continue ;; esac
    name="${raw%%#*}"
    rest="${raw#*#}"
    case "$rest" in *"/"*) ;; *) mput BADFMT "$stem" 1; continue ;; esac
    n="${rest%%/*}"
    m="${rest#*/}"
    case "$name" in ""|*[!a-z0-9-]*) mput BADFMT "$stem" 1; continue ;; esac
    case "$n" in ""|*[!0-9]*) mput BADFMT "$stem" 1; continue ;; esac
    case "$m" in ""|*[!0-9]*) mput BADFMT "$stem" 1; continue ;; esac
    if [ "$n" -lt 1 ] || [ "$m" -lt 1 ]; then mput BADFMT "$stem" 1; continue; fi
    mput SNAME "$stem" "$name"
    mput SN "$stem" "$n"
    mput SM "$stem" "$m"
    case " $SERIES_NAMES " in
      *" $name "*) ;;
      *) SERIES_NAMES="$SERIES_NAMES $name"
         mput SMEM "$name" "" ;;
    esac
    mget SMEM "$name"
    [ "$MV" = "-" ] && MV=""
    mput SMEM "$name" "${MV} ${stem}"
  done

  # 무결성: 같은 name 안에서 M 일치 / N 중복 없음 / N 이 1..M / 구성원 수 == M
  local sname s sn sm first_m cnt seen bad i members
  for sname in $SERIES_NAMES; do
    mget SMEM "$sname"; members="$MV"
    first_m=""; cnt=0; seen=""; bad=0
    for s in $members; do
      mget SN "$s"; sn="$MV"
      mget SM "$s"; sm="$MV"
      cnt=$((cnt + 1))
      if [ -z "$first_m" ]; then first_m="$sm"; elif [ "$sm" != "$first_m" ]; then bad=1; fi
      case " $seen " in *" $sn "*) bad=1 ;; esac
      seen="$seen $sn"
    done
    if [ "$bad" -eq 0 ] && [ "$cnt" -ne "$first_m" ]; then bad=1; fi
    if [ "$bad" -eq 0 ]; then
      i=1
      while [ "$i" -le "$first_m" ]; do
        case " $seen " in *" $i "*) ;; *) bad=1 ;; esac
        i=$((i + 1))
      done
    fi
    [ "$bad" -eq 1 ] && mput SBAD "$sname" 1
  done
  return 0
}

# ---------------------------------------------------------------- ③ 선행·dangling
# 맵: PREREQ(csv, 존재하는 stem 만) DANG(csv)

build_prereqs() {
  local stem one prq dang sname sn s on members bad_field
  for stem in $ALL_STEMS; do
    prq=""; dang=""
    bad_field=""
    mget DEP "$stem"; split_csv "$MV"
    for one in $SPLIT_OUT; do
      # 형식을 벗어난 토큰은 조회하지 않는다. 조용히 버리면 의존이 사라져 착수 불가 FR 이
      # ready 로 보이므로, 그 FR 자체를 error:parse:<필드명> 으로 만든다.
      if ! valid_stem "$one"; then bad_field="depends-on"; break; fi
      mget EX "$one"
      if [ "$MV" = "1" ]; then prq="${prq:+$prq,}$one"; else dang="${dang:+$dang,}$one"; fi
    done
    if [ -z "$bad_field" ]; then
      mget REL "$stem"; split_csv "$MV"
      for one in $SPLIT_OUT; do
        if ! valid_stem "$one"; then bad_field="relates"; break; fi
        mget EX "$one"
        [ "$MV" = "1" ] || dang="${dang:+$dang,}$one"
      done
    fi
    if [ -n "$bad_field" ]; then
      mput BADREF "$stem" "$bad_field"
      mput PREREQ "$stem" "-"
      mput DANG "$stem" "-"
      continue
    fi
    # series 선행 — 같은 name 에서 N 이 더 작은 구성원. 무결성 위반 시리즈는 건너뛴다
    # (구성원 전원이 이미 error:series 이므로 간선을 만들 의미가 없다).
    mget SNAME "$stem"; sname="$MV"
    if [ "$sname" != "-" ]; then
      mget SBAD "$sname"
      if [ "$MV" != "1" ]; then
        mget SN "$stem"; sn="$MV"
        mget SMEM "$sname"; members="$MV"
        for s in $members; do
          [ "$s" = "$stem" ] && continue
          mget SN "$s"; on="$MV"
          [ "$on" -lt "$sn" ] || continue
          case ",$prq," in *",$s,"*) ;; *) prq="${prq:+$prq,}$s" ;; esac
        done
      fi
    fi
    mput PREREQ "$stem" "${prq:--}"
    mput DANG "$stem" "${dang:--}"
  done
  return 0
}

# ---------------------------------------------------------------- ④ 순환 탐지

# 문자열 Kahn (batch_manifest.sh 이식). 한 라운드도 못 옮기면 잔여가 남는다.
# 잔여를 그대로 순환으로 보지 않는다 — 잔여 안에서 자기 자신으로 돌아오는 경로가 있는
# 노드만 cycle 이고, 나머지 잔여는 선행이 착수 불가일 뿐이라 waiting 이다.
detect_cycles() {
  local remaining="$ALL_STEMS" progress=1 nr s one ok
  while [ "$progress" -eq 1 ]; do
    progress=0; nr=""
    for s in $remaining; do
      mget PREREQ "$s"; split_csv "$MV"
      ok=1
      for one in $SPLIT_OUT; do
        mget KDONE "$one"
        [ "$MV" = "1" ] || ok=0
      done
      if [ "$ok" -eq 1 ]; then mput KDONE "$s" 1; progress=1; else nr="$nr $s"; fi
    done
    remaining="$nr"
  done
  [ -n "$remaining" ] || return 0

  local target frontier next n hit
  for target in $remaining; do
    mget PREREQ "$target"; split_csv "$MV"
    frontier="$SPLIT_OUT"
    hit=0
    # 방문 표시는 target 마다 새로 두어야 하므로 맵 이름에 target 을 섞는다.
    while [ -n "$frontier" ] && [ "$hit" -eq 0 ]; do
      next=""
      for n in $frontier; do
        case " $remaining " in *" $n "*) ;; *) continue ;; esac
        if [ "$n" = "$target" ]; then hit=1; break; fi
        mget "VIS${target//-/_}" "$n"
        [ "$MV" = "1" ] && continue
        mput "VIS${target//-/_}" "$n" 1
        mget PREREQ "$n"; split_csv "$MV"
        next="$next $SPLIT_OUT"
      done
      frontier="$next"
    done
    [ "$hit" -eq 1 ] && mput CYC "$target" 1
  done
  return 0
}

# ---------------------------------------------------------------- ⑤ 판정
# 맵: VERDICT

# 판정은 전체 items 를 대상으로 만든다. `readiness` 는 활성 FR 만 출력하고(계약 불변),
# `validate` 는 비활성 FR 의 관계 결함까지 보아야 하기 때문이다 — 시리즈 구성원이 전부
# done 이어도 번호·참조가 틀렸으면 검출해야 한다.
compute_verdicts() {
  local stem dang sname one st waiting checks v
  for stem in $ALL_STEMS; do
    v=""
    mget BADREF "$stem"; [ "$MV" != "-" ] && v="error:parse:${MV}"
    if [ -z "$v" ]; then
      mget BADFMT "$stem"; [ "$MV" = "1" ] && v="error:parse:series"
    fi
    if [ -z "$v" ]; then
      mget DANG "$stem"; dang="$MV"
      [ "$dang" != "-" ] && v="error:dangling:${dang}"
    fi
    if [ -z "$v" ]; then
      mget SNAME "$stem"; sname="$MV"
      if [ "$sname" != "-" ]; then
        mget SBAD "$sname"
        [ "$MV" = "1" ] && v="error:series:${sname}"
      fi
    fi
    if [ -z "$v" ]; then
      mget CYC "$stem"; [ "$MV" = "1" ] && v="error:cycle"
    fi
    if [ -z "$v" ]; then
      waiting=""; checks=""
      mget PREREQ "$stem"; split_csv "$MV"
      for one in $SPLIT_OUT; do
        mget ST "$one"; st="$MV"
        case "$st" in
          done) ;;
          dropped) checks="${checks:+$checks,}$one" ;;
          *) waiting="${waiting:+$waiting,}$one" ;;
        esac
      done
      if [ -n "$waiting" ]; then v="waiting:${waiting}"
      elif [ -n "$checks" ]; then v="check:${checks}"
      else v="ready"; fi
    fi
    mput VERDICT "$stem" "$v"
  done
  return 0
}

# 상세 파싱 → 시리즈 → 선행 → 순환 → 판정. 인덱스는 보지 않는다.
compute_relations() {
  parse_items || return 1
  build_series
  build_prereqs
  detect_cycles
  compute_verdicts
  [ "$MAP_ERR" -eq 0 ] || return 1
  return 0
}

# ---------------------------------------------------------------- 인덱스 읽기
# 맵: IHAS IPRI IREL ISUM

read_index() {
  if [ ! -f "$INDEX_FILE" ]; then
    ERR_REASON="인덱스 파일 없음: ${INDEX_FILE}"
    return 1
  fi
  local out rc rtype stem pri rel sum MAP_ERR_BEFORE
  out="$(awk '
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function nosp(s) { gsub(/[ \t\r]/, "", s); return s }
    # 센티널로 바꿔 둔 이스케이프 파이프를 원래 표기 `\|` 로 되돌린다.
    function unesc(s,   r, p) {
      r = ""
      while ((p = index(s, SEN)) > 0) { r = r substr(s, 1, p - 1) "\\|"; s = substr(s, p + 1) }
      return r s
    }
    # 행을 셀 배열 C[1..] 로 쪼개고 셀 수를 돌려준다. Markdown 에서 `\|` 는 셀 구분자가
    # 아니라 파이프 문자 자체이므로 먼저 센티널로 치환해 셀 수에서 제외한다. 이것을 세면
    # 요약의 `\|` 하나가 셀 수를 부풀려, 셀이 빠진 행이 정상 행과 같은 셀 수로 보인다.
    function cells(line,   t, n, i) {
      t = line
      gsub(/\\\|/, SEN, t)
      n = split(t, RAW, "|")
      for (i = 1; i <= n - 2; i++) C[i] = RAW[i + 1]   # 앞뒤 파이프가 만든 빈 조각은 버린다
      return n - 2
    }
    function colv(name,   c) {
      if (!(name in pos)) return ""
      c = pos[name]
      if (c <= 2) return trim(unesc(C[c]))
      if (c == 3) return trim(sum)
      return trim(unesc(C[K - N + c]))
    }
    function fail(msg) { failed = 1; printf "FAIL\034%s\n", msg; exit 0 }
    BEGIN { FS = "\n"; SEN = "\002"; inidx = 0; N = 0; failed = 0
            REQ = "날짜 제목 요약 종류 상태 우선순위 상세" }
    /^## / { inidx = ($0 ~ /^## 인덱스/) ? 1 : 0; next }
    inidx && /^\|/ {
      if (N == 0) {
        N = cells($0)
        if (N < 4) fail("인덱스 표 헤더 컬럼 수 부족 (" N "개, 최소 4개)")
        for (i = 1; i <= N; i++) pos[trim(unesc(C[i]))] = i
        nreq = split(REQ, req, " "); miss = ""
        for (i = 1; i <= nreq; i++)
          if (!(req[i] in pos)) miss = miss (miss == "" ? "" : ", ") req[i]
        if (miss != "") fail("인덱스 표 필수 헤더 없음: " miss)
        if (pos["요약"] != 3) fail("인덱스 표의 요약 컬럼이 3번째가 아님 (" pos["요약"] "번째)")
        next
      }
      if ($0 !~ /^\|[ \t]*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ \t]*\|/) next
      K = cells($0)
      # 행 본문을 잘라 넣지 않는다 — 한글 셀 중간에서 끊기면 진단이 깨진 바이트로 나온다.
      if (K < N) fail(FNR "행: 인덱스 데이터 행의 셀 수 부족 (헤더 " N "개, 행 " K "개)")
      sum = ""
      for (i = 3; i <= K - N + 3; i++) sum = (sum == "" ? unesc(C[i]) : sum "|" unesc(C[i]))
      # 요약에 이스케이프하지 않은 `|` 가 있으면 셀 수만으로는 정렬을 확인할 수 없다.
      # 오른쪽 고정 컬럼의 구조를 직접 본다 — 우선순위 셀은 `P<숫자>` 또는 `-` 뿐이다.
      # 셀이 빠져 오른쪽이 한 칸씩 밀리면 다른 컬럼 값이 여기로 들어와 형식이 어긋난다.
      pv = nosp(colv("우선순위")); if (pv == "") pv = "-"
      if (pv !~ /^(-|P[0-9]+)$/)
        fail(FNR "행: 우선순위 셀 형식 오류 (기대: P<숫자> 또는 -, 실제: " pv ") — 셀 수 또는 컬럼 정렬 확인 필요")
      d = colv("상세")
      stem = ""
      if (match(d, /items\/[A-Za-z0-9_.-]+\.md/)) {
        stem = substr(d, RSTART, RLENGTH); sub(/^items\//, "", stem); sub(/\.md$/, "", stem)
      }
      if (stem == "") stem = colv("날짜") "-" colv("제목")
      p = pv
      r = nosp(colv("관계")); if (r == "") r = "-"
      printf "ROW\034%s\034%s\034%s\034%s\n", stem, p, r, trim(sum)
      next
    }
    END { if (!failed && N == 0) print "FAIL\034인덱스 표 헤더를 찾을 수 없음" }
  ' "$INDEX_FILE" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    ERR_REASON="인덱스 파싱 실행 오류 (awk rc=${rc}): ${out}"
    return 1
  fi
  MAP_ERR_BEFORE="$MAP_ERR"
  while IFS=$'\034' read -r rtype stem pri rel sum; do
    if [ "$rtype" = "FAIL" ]; then
      # 헤더·데이터 행 구조 손상. 인덱스를 신뢰할 수 없으므로 실행 불가로 끝낸다 —
      # 조용히 건너뛰면 그 행의 priority 가 사라져 auto-pick 이 다른 FR 을 고른다.
      ERR_REASON="${stem} (${INDEX_FILE})"
      return 1
    fi
    [ "$rtype" = "ROW" ] || continue
    if ! valid_stem "$stem"; then
      # 헤더·행 구조 손상과 같은 결로 다룬다 — 인덱스를 신뢰할 수 없으므로
      # 인덱스를 읽는 서브커맨드(validate·auto-pick)를 실행 불가로 끝낸다.
      ERR_REASON="인덱스 행의 stem 형식 오류 (기대: YYYY-MM-DD-<slug>): ${stem}"
      return 1
    fi
    mput IHAS "$stem" 1
    mput IPRI "$stem" "$pri"
    mput IREL "$stem" "$rel"
    mput ISUM "$stem" "$sum"
  done <<< "$out"
  [ "$MAP_ERR" = "$MAP_ERR_BEFORE" ] || return 1
  return 0
}

# ---------------------------------------------------------------- 인덱스 기대값

# expected_relation <stem> — 상세 필드에서 만든 표준 관계 문자열(공백 없음).
# series 형식 오류 FR 은 rc=1 로 돌려주어 호출자가 검사를 건너뛰게 한다.
EXP_REL=""
expected_relation() {
  local stem="$1" sname sn sm deps
  EXP_REL=""
  mget BADREF "$stem"; [ "$MV" != "-" ] && return 1
  mget BADFMT "$stem"; [ "$MV" = "1" ] && return 1
  mget SNAME "$stem"; sname="$MV"
  if [ "$sname" != "-" ]; then
    mget SN "$stem"; sn="$MV"
    mget SM "$stem"; sm="$MV"
    EXP_REL="series:${sname}#${sn}/${sm}"
  fi
  mget DEP "$stem"; deps="$MV"
  if [ "$deps" != "-" ] && [ -n "$deps" ]; then
    EXP_REL="${EXP_REL:+${EXP_REL};}dep:${deps}"
  fi
  [ -n "$EXP_REL" ] || EXP_REL="-"
  return 0
}

# ---------------------------------------------------------------- readiness

cmd_readiness() {
  local buf="" stem
  compute_relations || { echo "fr_relations.sh: ${ERR_REASON}" >&2; return 2; }
  for stem in $ACTIVE_STEMS; do
    mget VERDICT "$stem"
    buf="${buf}${stem}	${MV}
"
  done
  printf '%s' "$buf"
  return 0
}

# ---------------------------------------------------------------- validate

cmd_validate() {
  local buf="" viol=0 stem v dang sname raw one pfx sn sm dpri ipri irel isum sht
  compute_relations || { echo "fr_relations.sh: ${ERR_REASON}" >&2; return 2; }
  read_index || { echo "fr_relations.sh: ${ERR_REASON}" >&2; return 2; }

  local badname
  while IFS= read -r badname; do
    [ -n "$badname" ] || continue
    buf="${buf}item-filename	${badname}	items/ 파일명 형식 오류 (기대: YYYY-MM-DD-<slug>.md) — 판정에서 제외됨
"
    viol=1
  done <<< "$BAD_ITEM_NAMES"

  # 관계 자체의 검증은 전체 items 가 대상이다. 인덱스 사본·앞머리 대조는 아래 IHAS
  # 게이트로 실제 인덱스 행이 있는 FR 에만 적용한다.
  for stem in $ALL_STEMS; do
    mget VERDICT "$stem"; v="$MV"
    case "$v" in
      error:parse:depends-on|error:parse:relates)
        buf="${buf}parse	${stem}	관계 필드 값 형식 오류 (${v#error:parse:}) — stem 형식 YYYY-MM-DD-<slug> 이 아닌 토큰
"
        viol=1 ;;
    esac
    case "$v" in
      error:parse:series)
        mget SRAW "$stem"; raw="$MV"
        buf="${buf}series	${stem}	- series: 필드 형식 오류 (기대: <name> #N/M): ${raw}
"
        viol=1 ;;
      error:dangling:*)
        dang="${v#error:dangling:}"
        buf="${buf}dangling	${stem}	존재하지 않는 stem 참조: ${dang}
"
        viol=1 ;;
      error:series:*)
        sname="${v#error:series:}"
        buf="${buf}series	${stem}	시리즈 무결성 위반 (name=${sname}): 구성원 번호가 1..M 과 일치하지 않음
"
        viol=1 ;;
      error:cycle)
        buf="${buf}cycle	${stem}	순환 의존 (depends-on + series 선행 합산 그래프)
"
        viol=1 ;;
    esac

    mget IHAS "$stem"; [ "$MV" = "1" ] || continue
    mget IPRI "$stem"; ipri="$MV"
    mget IREL "$stem"; irel="$MV"
    mget ISUM "$stem"; isum="$MV"

    # index-column — 상세에서 만든 표준 문자열과 인덱스 관계 칸을 공백 제거 후 비교
    if expected_relation "$stem"; then
      if [ "$EXP_REL" != "$irel" ]; then
        buf="${buf}index-column	${stem}	인덱스 관계 칸 불일치 (상세=${EXP_REL}, 인덱스=${irel})
"
        viol=1
      fi

      # summary-prefix — 관계가 있는 FR 의 요약은 `**[...]**` 앞머리를 가져야 한다
      if [ "$EXP_REL" != "-" ]; then
        case "$isum" in
          '**['*)
            pfx="${isum#\*\*\[}"; pfx="${pfx%%]*}"
            mget DEP "$stem"; split_csv "$MV"
            for one in $SPLIT_OUT; do
              sht="${one:11}"
              case "$pfx" in
                *"$sht"*) ;;
                *)
                  buf="${buf}summary-prefix	${stem}	요약 앞머리에 선행 short-title 없음: ${sht}
"
                  viol=1 ;;
              esac
            done
            mget SNAME "$stem"; sname="$MV"
            if [ "$sname" != "-" ]; then
              mget SN "$stem"; sn="$MV"
              mget SM "$stem"; sm="$MV"
              case "$pfx" in
                *"${sn}/${sm}"*) ;;
                *)
                  buf="${buf}summary-prefix	${stem}	요약 앞머리에 시리즈 번호 없음: ${sn}/${sm}
"
                  viol=1 ;;
              esac
            fi
            ;;
          *)
            buf="${buf}summary-prefix	${stem}	관계가 있는데 요약 앞머리(**[...]**)가 없음
"
            viol=1 ;;
        esac
      fi
    fi

    # priority-drift — 경고 전용 (exit 0)
    mget PRI "$stem"; dpri="$MV"
    if [ "$dpri" != "-" ] && [ "$dpri" != "$ipri" ]; then
      buf="${buf}priority-drift	${stem}	상세=${dpri}, 인덱스=${ipri} (권위는 인덱스 — 경고)
"
    fi
  done

  printf '%s' "$buf"
  [ "$viol" -eq 1 ] && return 1
  return 0
}

# ---------------------------------------------------------------- batch-draft

cmd_batch_draft() {
  local buf="" rc=0 slug stem matches cnt s
  local resolved=""
  if [ -z "$SLUGS" ]; then
    echo "fr_relations.sh: batch-draft 에 --slugs 가 필요합니다." >&2
    return 2
  fi
  compute_relations || { echo "fr_relations.sh: ${ERR_REASON}" >&2; return 2; }

  # slug → stem 해결. `resolve-slug` 와 같은 규칙이다 — 정확히 1건일 때만 진행한다.
  for slug in $SLUGS; do
    case "$slug" in
      ""|*[!a-z0-9-]*)
        echo "fr_relations.sh: slug 형식 오류 — '${slug}' (허용: [a-z0-9-])" >&2
        return 2 ;;
    esac
    matches=""; cnt=0
    for s in $ALL_STEMS; do
      case "$s" in
        ????-??-??-"$slug") matches="$matches $s"; cnt=$((cnt + 1)) ;;
      esac
    done
    if [ "$cnt" -ne 1 ]; then
      echo "fr_relations.sh: slug 해결 실패 — '${slug}' 매칭 ${cnt}건 (정확히 1건이어야 합니다)" >&2
      return 2
    fi
    stem="${matches# }"
    resolved="$resolved $stem"
    mput SLUG "$slug" "$stem"
  done

  local v one dep_list ext_ok ext_unmet st
  for slug in $SLUGS; do
    mget SLUG "$slug"; stem="$MV"
    # 비활성(done·dropped·parked) FR 은 batch 대상이 아니다. status 로 직접 본다 —
    # VERDICT 는 전체 items 에 대해 만들어지므로 부재로 비활성을 가려낼 수 없다.
    mget ST "$stem"; st="$MV"
    case "$st" in
      done|dropped|parked)
        buf="${buf}${slug}	error	비활성 FR (status=${st})
"
        rc=1
        continue ;;
    esac
    mget VERDICT "$stem"; v="$MV"
    case "$v" in
      error:*)
        buf="${buf}${slug}	error	${v#error:}
"
        rc=1
        continue ;;
    esac
    dep_list=""; ext_ok=""; ext_unmet=""
    mget PREREQ "$stem"; split_csv "$MV"
    for one in $SPLIT_OUT; do
      case " $resolved " in
        *" $one "*) dep_list="${dep_list:+$dep_list }${one:11}"; continue ;;
      esac
      mget ST "$one"; st="$MV"
      if [ "$st" = "done" ]; then ext_ok="${ext_ok:+$ext_ok }$one"
      else ext_unmet="${ext_unmet:+$ext_unmet }$one"; fi
    done
    [ -n "$dep_list" ] && buf="${buf}${slug}	depends_on	${dep_list}
"
    [ -n "$ext_ok" ] && buf="${buf}${slug}	external-satisfied	${ext_ok}
"
    [ -n "$ext_unmet" ] && buf="${buf}${slug}	external-unmet	${ext_unmet}
"
  done

  printf '%s' "$buf"
  return "$rc"
}

# ---------------------------------------------------------------- auto-pick

# 다음 조치 문구 — change spec D6 의 네 가지.
next_action_for() {
  local v="$1" one out=""
  case "$v" in
    waiting:*)
      split_csv "${v#waiting:}"
      for one in $SPLIT_OUT; do out="${out:+$out, }${one:11}"; done
      printf '선행 %s 완료 필요' "$out" ;;
    check:*)   printf '선행 상태와 depends-on·series 관계를 확인·수정한 뒤 재판정' ;;
    *)         printf 'fr_relations.sh validate 로 관계 데이터 수정' ;;
  esac
}

state_label_for() {
  local v="$1" one out=""
  case "$v" in
    ready) printf '착수 가능' ;;
    waiting:*)
      split_csv "${v#waiting:}"
      for one in $SPLIT_OUT; do out="${out:+$out, }${one:11}"; done
      printf '대기(선행: %s)' "$out" ;;
    check:*)
      split_csv "${v#check:}"
      for one in $SPLIT_OUT; do out="${out:+$out, }${one:11}"; done
      printf '확인 필요(선행 dropped: %s)' "$out" ;;
    error:*) printf '오류(%s)' "${v#error:}" ;;
    *) printf '%s' "$v" ;;
  esac
}

emit_unavailable() {
  printf 'unavailable\n'
  printf '%s\t%s\t%s\n' "-" "$ERR_REASON" "$ERR_ACTION"
}

cmd_auto_pick() {
  local stem st v eligible="" selectable=""
  # ① 상세 파싱 → ② 판정 계산
  compute_relations || { emit_unavailable; return 2; }
  for stem in $ACTIVE_STEMS; do
    mget ST "$stem"; st="$MV"
    case "$st" in
      validated|ready-for-request) ;;
      *) continue ;;
    esac
    eligible="$eligible $stem"
    mget VERDICT "$stem"; v="$MV"
    [ "$v" = "ready" ] && selectable="$selectable $stem"
  done

  # ③ 인덱스 읽기 (priority 정렬용). 여기서 실패해도 위 판정은 이미 만들어져 있다.
  read_index || { emit_unavailable; return 2; }

  # ④ 선택
  local buf=""
  if [ -n "$selectable" ]; then
    local best="" best_rank=9 best_date="" rank
    for stem in $selectable; do
      mget IPRI "$stem"
      case "$MV" in
        P1) rank=1 ;; P2) rank=2 ;; P3) rank=3 ;; *) rank=4 ;;
      esac
      if [ -z "$best" ] || [ "$rank" -lt "$best_rank" ] \
         || { [ "$rank" -eq "$best_rank" ] && [ "${stem:0:10}" \< "$best_date" ]; }; then
        best="$stem"; best_rank="$rank"; best_date="${stem:0:10}"
      fi
    done
    buf="select	${best}
"
  elif [ -z "$eligible" ]; then
    buf="queue-empty
"
  else
    buf="queue-blocked
"
    for stem in $eligible; do
      mget VERDICT "$stem"; v="$MV"
      buf="${buf}${stem:11}	$(state_label_for "$v")	$(next_action_for "$v")
"
    done
  fi

  # ⑤ 출력
  printf '%s' "$buf"
  return 0
}

# ---------------------------------------------------------------- 진입점

case "$CMD" in
  readiness)   cmd_readiness ;;
  validate)    cmd_validate ;;
  batch-draft) cmd_batch_draft ;;
  auto-pick)   cmd_auto_pick ;;
  ""|-h|--help|help)
    echo "usage: fr_relations.sh {readiness|validate|batch-draft|auto-pick} [--root <ROOT>] [--slugs \"<s> <s>\"]" >&2
    exit 2 ;;
  *)
    echo "fr_relations.sh: 알 수 없는 서브커맨드: ${CMD}" >&2
    exit 2 ;;
esac
exit $?
