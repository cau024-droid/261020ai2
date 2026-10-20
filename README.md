# 크레이지 버블

Godot 4.3 + Supabase Realtime으로 만든 크레이지 아케이드 스타일 물풍선 게임입니다.

- 혼자 들어가면 AI 봇(최대 3명)과 대전합니다.
- 같은 방 코드(또는 초대 링크 `?room=코드`)로 들어온 사람은 실시간으로 함께 플레이합니다. 최대 4명이고, 남는 자리는 봇이 채웁니다.
- 조작: 방향키/WASD로 이동, Space로 물풍선. 모바일은 화면 왼쪽을 드래그해서 이동하고 오른쪽을 탭합니다.
- 물줄기에 맞으면 3초 동안 물방울에 갇히고, 그사이 상대가 건드리면 터집니다. 마지막까지 남은 사람이 이깁니다.

## 구조

| 파일 | 역할 |
| --- | --- |
| `scripts/net.gd` | Supabase Realtime 클라이언트 (WebSocket, Phoenix 프로토콜). Broadcast로 게임 메시지, Presence로 방 인원 관리 |
| `scripts/game.gd` | 맵, 물풍선, 아이템, 봇 AI, 동기화, 그리기 |
| `scripts/main.gd` | 메뉴와 대기실 UI, 메시지 라우팅 |
| `build.sh` / `vercel.json` | Vercel 빌드: Godot와 웹 템플릿을 받아 `build/`로 내보냄 |

방장(가장 먼저 들어온 사람)이 맵, 폭발, 아이템, 봇, 탈락 판정을 맡고 초당 10번 상태를 보냅니다. 각자의 캐릭터 이동은 자기 화면에서 바로 처리하고 위치를 보냅니다. 방장이 나가면 다음 사람이 이어받습니다.

Supabase 프로젝트 `ootd-store`의 Realtime 채널(`crazy-bubble-<방코드>`)만 사용하고 DB 테이블은 건드리지 않습니다.

## Vercel 배포

1. 이 폴더를 GitHub 저장소로 올립니다.
   ```bash
   git init && git add . && git commit -m "Crazy Bubble" && git branch -M main
   git remote add origin https://github.com/<아이디>/crazy-bubble.git && git push -u origin main
   ```
2. vercel.com → Add New → Project → 저장소 Import.
3. 설정은 `vercel.json`이 자동으로 채웁니다 (Framework: Other, Build: `bash build.sh`, Output: `build`). Deploy를 누릅니다.
4. 첫 빌드는 Godot 템플릿(약 1GB)을 받느라 3~6분 걸립니다. 끝나면 나오는 `https://<프로젝트>.vercel.app` 링크를 공유하면 됩니다.

## 로컬 실행

Godot 4.3 에디터로 `project.godot`을 열고 F5를 누릅니다. 로컬에서 실행해도 같은 Supabase 방에 접속되므로, 웹 버전 사용자와 같이 플레이할 수 있습니다.

헤드리스 시뮬레이션 테스트:

```bash
godot --headless --path . res://tests/sim_test.tscn
```
