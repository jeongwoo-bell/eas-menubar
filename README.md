# EAS Builds — 메뉴바에서 Expo 빌드 상태 보기

macOS 메뉴바의 망치 아이콘을 누르면 지금 EAS에서 뭐가 빌드되고 있는지, 언제쯤 끝날지, 최근 빌드가 성공했는지 바로 보여줍니다.

```
🔨 28분                                         ← 메뉴바
────────────────────────────────────────────
빌드 중 · preview
🟠 Android · a1b2c3d feat: 결제 화면 리뉴얼
      ▰▰▰▰▰▰▰▰▰▰▰▱   28분 경과 · 약 2분 남음
최근
🟢 iOS · a1b2c3d feat: 결제 화면 리뉴얼 · 19분 전
🟢 iOS · 9f8e7d6 refactor: api client · 1일 전
🟢 Android · 9f8e7d6 refactor: api client · 1일 전
────────────────────────────────────────────
방금 갱신 · 빌드 중엔 15초마다
새로고침
expo.dev에서 빌드 목록 보기
설정 ▸
```

## 설치

터미널에 한 줄만 붙여넣으세요.

```bash
curl -fsSL https://raw.githubusercontent.com/jeongwoo-bell/eas-menubar/main/install.sh | bash
```

저장소가 비공개라 위 명령이 404로 실패하면, GitHub CLI(`gh auth login`)로 로그인한 뒤 아래 중 하나로 설치하세요.

```bash
gh api repos/jeongwoo-bell/eas-menubar/contents/install.sh -H "Accept: application/vnd.github.raw" | bash
```

```bash
git clone https://github.com/jeongwoo-bell/eas-menubar.git && cd eas-menubar && ./install.sh
```

설치 스크립트가 다음을 순서대로 처리합니다.

1. SwiftBar(메뉴바 플러그인 앱)가 없으면 Homebrew로 설치
2. 플러그인과 `eas-builds` 명령어 설치
3. 설정 화면 실행: eas-cli 확인 → EAS 로그인 → Mac에서 Expo 프로젝트를 찾아 볼 앱 선택

```
  어떤 앱의 빌드를 메뉴바에 띄울까요?
 › ◉ My App      ~/dev/my-app
   ◉ My Admin    ~/dev/my-admin
   ◯ Legacy      ~/work/legacy-app
   ↑↓ 이동 · space 선택 · a 전체 · enter 완료   (2개 선택됨)
```

**필요한 것:** macOS, Node.js, EAS를 쓰는 Expo 프로젝트 (eas-cli는 없으면 설정 중에 설치를 제안해요)

## 사용법

| 명령 | 하는 일 |
|---|---|
| `eas-builds setup` | 로그인 확인 + 볼 앱 다시 고르기 |
| `eas-builds add [폴더]` | 프로젝트 추가 (기본: 현재 폴더) |
| `eas-builds list` | 추적 중인 프로젝트 목록 |
| `eas-builds refresh` | 지금 새로고침 |
| `eas-builds login` | EAS 로그인 |
| `eas-builds uninstall` | 플러그인과 설정 삭제 |

메뉴에서 할 수 있는 것:

- 빌드 줄 클릭 → expo.dev 빌드 페이지
- 빌드 줄에 마우스 올리기 → 커밋 메시지, 버전, 빌드한 사람, 소요 시간, 실패 사유, 앱 파일 다운로드, 커밋 해시 복사, 빌드 취소
- **설정** → 프로젝트 추가/빼기, 완료 알림 켜기/끄기, 끝난 빌드 표시 개수

## 동작 방식

- 각 프로젝트 폴더에서 `eas build:list --json`을 실행해 결과를 캐시합니다. 메뉴를 열면 캐시를 즉시 보여주고 뒤에서 새로 받아옵니다(stale-while-revalidate). 그래서 클릭하자마자 열립니다.
- 빌드 중이면 15초, 아니면 60초마다 갱신합니다.
- 남은 시간은 같은 플랫폼·프로필로 최근 성공한 빌드 5개의 평균 소요 시간으로 추정합니다.
- 빌드가 끝나면 macOS 알림이 오고, 알림을 누르면 빌드 페이지가 열립니다. (처음 한 번 SwiftBar 알림 권한을 허용해 주세요)
- 인증은 각자 로그인한 `eas` 세션을 그대로 씁니다. 토큰을 따로 저장하지 않아요.

파일 위치:

- 설정: `~/.config/eas-builds/config.json`
- 캐시: `~/Library/Caches/eas-builds/` (SwiftBar가 정해주는 경로가 있으면 그쪽)

## 문제 해결

| 증상 | 해결 |
|---|---|
| ⚠️ "EAS 로그인이 필요해요" | 메뉴에서 "터미널에서 eas login 실행" 또는 `eas-builds login` |
| "eas-cli를 찾을 수 없어요" | `npm install -g eas-cli`. nvm/volta/fnm 외 위치에 설치했다면 플러그인 상단 PATH 줄에 추가 |
| 메뉴바에 아이콘이 안 보임 | SwiftBar 실행 여부 확인, 메뉴바 공간이 부족하면 다른 아이콘을 ⌘ 드래그로 정리 |
| 갱신이 멈춘 것 같음 | `eas-builds refresh`, 그래도 안 되면 `rm -rf ~/Library/Caches/eas-builds` |
