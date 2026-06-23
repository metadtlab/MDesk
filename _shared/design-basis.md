# Design Basis — 왜 이 시스템이 이렇게 생겼나

> **로드 정책**: 이 파일은 평소 작업에서 읽지 않는다. 시스템 파일(`AGENTS.md`, `_shared/*`, `_templates/*`)을 수정·검증할 때만 읽는다.

## 0. 출처

- 원본 starter: multi-agent-starter
- Codex flavor: multi-agent-starter의 Codex orchestrator 파생본
- 사용자 결정: Codex가 메인 오케스트레이터가 되며, Codex 산출물 비평은 자기검수인 `codex-critic`이 아니라 독립성 있는 `claude-critic`이 맡는다.

## 1. 핵심 개념 → 시스템 규칙 매핑

| 개념 | 시스템 규칙 | 주의 |
|------|-------------|------|
| 컨텍스트 = 유한 attention budget | context.md <= 1500자, brief <= 1200자 | 한도 변경 시 불변식 갱신 |
| Progressive disclosure | sources/ 경로 참조, brief 최소화 | 긴 자료 inline 금지 |
| Filesystem = memory | task/context/log/brief/result | 런타임 상태에 의존하지 않음 |
| Append-only + provenance | log.md append-only, 태그 6종 | 로그 삭제·수정 금지 |
| Never trust upstream | worker result 검증 후 채택 | critic/gemini 출력도 사실검증 |
| Adversarial review | `claude-critic` | Codex 자기검수로 대체 금지 |
| 최소 worker set | routing.md decision tree | 모든 worker 기본 호출 금지 |
| Fan-in 충돌 해소 | 출처 병기, 사실검증, `[DECISION]` | 다수결 금지 |

## 2. 권위 우선순위

`AGENTS.md` > `_shared/routing.md`·`approval-policy.md`·`orchestrator-rules.md` > `_templates/*`.

충돌 발견 시 낮은 쪽을 높은 쪽에 맞추고, 작업 중인 task의 `log.md`에 `[DECISION]`으로 남긴다.

## 3. 결정 기록

- **D1 write_scope 값 집합** = `none | tasks-only | "패턴"`. `tasks-only`는 `tasks/<task>/` 내부만 쓰는 기본값이다.
- **D2 critic 역할** = Codex 버전에서 산출물 리뷰 worker는 `claude-critic`이다. Codex가 자기 산출물을 다시 검수하는 `codex-critic` 구조는 사용하지 않는다.
- **D3 claude-critic 선행조건** = 리뷰 대상 산출물 경로가 존재해야 한다. 대상은 `codex-main result.md`로 한정하지 않고, Orchestrator 산출물·기존 코드·문서·소스도 가능하다.
- **D4 gemini 정책** = 백엔드 Antigravity `agy` CLI(`_shared/backends.json` 정본, 디스패처 `call_worker.sh`). 기본 `gemini-3.1-pro-high`, 빠른 경로 `gemini-3-flash`/`pro-low`, 폴백 `api`. 옛 `mcp__gemini-pro__*` 프록시 브리지 폐기. `pro-high` 제외 사유(옛 프록시 400)는 agy엔 비해당(2026-06-02 실증). agy 모델은 전역·계정단위라 gemini 전용 전역을 pro-high로 운용.
- **D5 Orchestrator** = Codex 현재 세션이 단일 Orchestrator다. 별도 long-lived supervisor worker나 worker 재귀 위임 계층은 쓰지 않는다.
- **D6 모델 식별자 표기** = Codex와 Claude는 환경 설정/별칭을 따르고 repo에 버전 문자열을 핀하지 않는다. Gemini는 백엔드 `agy` CLI·기본 `gemini-3.1-pro-high`를 `backends.json`에 명시 핀(agy 모델이 전역·계정단위라 per-call 핀 불가). 세부는 D4.

## 4. 불변식

구체 항목과 점검 명령은 `_shared/system-invariants.md`에 둔다.
