# macOS SSH 접속 관리자 설계

상태: 사용자 승인 후 첫 구현 작성. 전체 앱 빌드 및 SSH 테스트 14개 통과. GUI 조작 검증은 자동화 연결 시간 초과로 미완료; 기존 키보드 테스트 1개는 한글 입력 상태에서 실패.

## 구현 시 확정한 변경

아래 내용은 후속 상세 설명보다 우선한다.

- 별도 타깃과 비밀 IPC 대신 같은 서명된 Ghostty 실행 파일을 초기 진입점에서 launcher/askpass로 실행한다. 도우미는 Keychain을 직접 읽으며 앱 UI 이벤트 루프에 의존하지 않는다.
- 실행 명세는 비밀 없는 0700 임시 디렉터리/0600 JSON이다. 인증 도우미는 부모가 Apple 서명된 `/usr/bin/ssh`이고 그 부모가 동일한 서명 요구사항을 충족하는 launcher인지 검사한다. 경로 비교에는 libc realpath를 사용한다.
- Keychain 값에 접속 설정을 함께 결합하여 다른 목적지로 참조 ID를 옮겨도 자동 사용하지 않는다. 접속 설정 변경 시 비밀을 다시 입력한다.
- SSH 실행은 Foundation.Process 대신 foreground process group을 유지하는 posix_spawn을 쓴다. HUP/TERM은 자식 종료와 임시 파일 정리를 수행하고 인증창은 launcher 소멸 시 닫힌다.
- 종료 화면의 재접속 UI는 터미널의 R/M + Enter 입력으로 제공한다. 실행 중/인증 성공 상태 배지는 제공하지 않는다.
- 인증서+개인 키는 OpenSSH의 기본 공개 키 동작을 사용한다. 인증서만 강제하는 모드가 아니며 UI에 이 사실을 명시한다.
- 전체 구현·검증 기록은 ../plans/2026-11-09-macos-ssh-session-manager.md 및 macos/Tests/SSH/README.md에 기록한다.

## 목적과 확정 요구사항

macOS Ghostty에서 SecureCRT처럼 접속 정보를 관리하고 선택 즉시 SSH 탭을 연다. 서버 비밀번호 저장과 자동 로그인, 개인 키 및 OpenSSH 사용자 인증서 인증을 지원한다. 사용자는 macOS OpenSSH와 전용 인증 도우미를 사용하는 방향 및 제안한 첫 버전 범위에 동의했다. 아래 세부 정책은 설계 제안이다.

성공 기준은 저장한 서버를 검색하여 Enter 한 번으로 접속하고, 재실행 후에도 접속 정보와 Keychain 인증 정보를 사용할 수 있는 것이다.

## 접근 방식

1. **채택: 시스템 OpenSSH + 인증 도우미.** SSH 설정·에이전트·인증서 호환성을 시스템에 맡긴다. 앱은 목록, Keychain, 인증 UI, 터미널 실행을 담당한다. 도우미 패키징과 인증 요청 전달이 필요하다.
2. **미채택: SSH 라이브러리 내장.** 연결 상태와 인증을 직접 제어할 수 있지만 OpenSSH 인증서 및 설정 호환성, 터미널 연결 유지보수 범위가 커진다.

공유 Zig 코어와 C API는 우선 변경하지 않는다. macOS SwiftUI/AppKit 기능으로 구현한다.

## 첫 버전 사용자 경험

메뉴의 ‘SSH 접속 관리자’에서 독립 관리 창을 연다. 왼쪽에는 전체·즐겨찾기·폴더, 중앙에는 검색 가능한 접속 목록을 배치한다. 상세 편집은 시트로 제공한다. 상시 터미널 사이드바는 첫 버전에 포함하지 않는다.

- 이름·호스트·사용자로 검색, 폴더별 정리, 즐겨찾기.
- 추가·수정·복제·삭제. 복제 시 비밀 정보는 복제하지 않으며 다시 지정한다.
- 더블클릭·Enter는 새 탭, 컨텍스트 메뉴는 새 창 접속. 기존 터미널이 없으면 새 창.
- 편집 항목: 이름, 폴더, 대상 호스트 또는 SSH 별칭, 선택적 사용자·포트, 인증 방식, 키·인증서 파일, 비밀번호 저장 선택.
- 인증 방식: SSH 설정 따르기 / 비밀번호 / 개인 키 / 개인 키 + 인증서.
- 비밀번호는 기본 마스킹하며 저장 여부와 저장된 항목 제거 기능을 제공한다. 개인 키 암호도 같은 원칙을 적용한다.
- 접속 종료 후 출력과 종료 코드를 남기고 재접속 버튼을 제공한다. 자동 재접속은 하지 않는다.
- 실행 중 프로필을 수정해도 현재 연결은 유지되며 다음 접속부터 반영한다. 프로필 삭제는 기존 연결을 끊지 않는다.

연결 상태는 ‘실행 준비·실행 중·종료·시작 실패’만 표시한다. 로컬 ssh 프로세스 실행을 인증 성공이나 원격 연결 완료로 표시하지 않는다.

## 저장 모델

`~/Library/Application Support/<실행 앱 bundle identifier>/ssh-sessions.json`에 버전 있는 Codable 문서를 저장한다. 기존 Ghostty 설정 파일과 분리한다.

- 문서: schemaVersion, folders, profiles.
- 폴더: UUID, 이름, 정렬 순서. 첫 버전은 단일 깊이.
- 프로필: UUID, 이름, folderID, 즐겨찾기, destination, 선택적 username·port, authenticationMode, identityFileURL, certificateFileURL, credentialID 참조, 정렬 순서.
- 실행 시도: 별도 UUID, 프로필 스냅샷, surface 연결, 종료 상태. 디스크에는 실행 토큰이나 비밀을 저장하지 않는다.

목적지는 단일 호스트·IP·SSH 별칭으로 제한한다. 사용자와 포트는 별도 필드다. 공백·제어 문자·옵션으로 해석될 선행 하이픈은 거부한다. 포트는 1–65535다. 파일 경로는 파일 선택기로 받고 argv 값으로 전달한다.

파일은 원자 교체로 저장하고 디렉터리 0700, 파일 0600을 적용한다. 읽기 실패나 알 수 없는 상위 스키마는 오류를 표시하고 원본을 덮어쓰지 않는다. 앱 내 저장은 단일 저장소가 직렬화한다. 외부 동시 수정은 감지 후 재읽기 또는 사용자 선택을 요구한다.

비밀은 Security.framework의 Keychain generic-password 항목으로 저장한다. 서비스는 앱 식별자 기반, 계정 키는 credential UUID와 용도다. 서버 비밀번호와 키 암호를 구분하고 iCloud 동기화는 사용하지 않는다. 개인 키 자체는 복사하거나 Keychain에 넣지 않고 원래 파일을 참조한다.

비밀 변경은 새 Keychain 항목 작성 → JSON 참조 교체 → 이전 항목 제거 순서다. JSON 저장 실패 시 새 항목을 정리한다. 제거 실패는 재시도 가능한 정리 대상으로 남기되 비밀 값을 기록하지 않는다. 삭제는 JSON 참조 제거 후 Keychain 항목을 정리한다. 잠금·권한 거부를 ‘저장된 비밀번호 없음’으로 처리하지 않고 재시도/이번만 입력/취소를 제공한다.

## 컴포넌트와 기존 코드 연결

`macos/Sources/Features/SSH/` 아래에 다음 책임을 둔다.

- SessionStore: 모델, 저장·마이그레이션, 변경 알림.
- CredentialStore: Keychain 접근과 오류 변환.
- SessionManagerView / Editor: 목록과 편집.
- SSHLaunchCoordinator: 검증, 실행 스냅샷, 인증 생명주기, 탭·창 생성.
- SSHInvocationBuilder: 검증된 구조에서 실행 인자 생성. 자유 형식 명령 입력은 제공하지 않는다.
- AuthenticationBroker: 접속 시도별 요청과 Keychain 조회·사용자 인증 UI 연결.
- 번들 실행 도우미: launcher와 askpass 역할. 별도 서명된 실행 타깃으로 패키징한다.

메뉴 연결은 AppDelegate/MainMenu.xib를 사용한다. 탭·창 생성은 TerminalController.newTab/newWindow와 SurfaceConfiguration.command/environmentVariables/waitAfterCommand를 재사용한다.

SurfaceConfiguration.command는 문자열이므로 사용자 값을 이 문자열에 합치지 않는다. 앱 번들 launcher 경로를 검증된 셸 인용 함수로 인용한 고정 명령만 전달한다. launcher는 인증된 로컬 IPC로 비밀 없는 실행 명세를 받고 `/usr/bin/ssh`를 argv 배열로 실행한다. 기존 PTY를 상속한다. 임의 사용자 셸 초기화에 의존하지 않는다.

launcher는 ssh 자식의 종료를 기다려 앱에 종료 코드를 전달하고 종료한다. 창 닫기·취소 시 자식에도 신호를 전달하고, 앱 또는 IPC 소멸 시 인증 요청을 종료한다. 분할·새 탭에는 이 실행 명세와 인증 환경을 상속하지 않는다. 복원된 창에서 SSH 자동 접속이나 비밀번호 자동 제출은 하지 않고 명시적 재접속을 요구한다.

## SSH 실행 정책

`/usr/bin/ssh`를 PTY에서 실행한다. 사용자 지정 필드는 CLI 옵션으로, 미지정 필드는 기존 SSH 설정으로 처리한다. `~/.ssh/config`를 수정하거나 자체 파서로 재구현하지 않는다. 별칭은 사용자가 입력하며 자동 목록 수집은 후속 범위다.

명시적 키는 IdentityFile, 인증서는 CertificateFile로 전달하고 IdentitiesOnly=yes를 적용한다. 개인 키 + 인증서 모드는 지정한 키와 인증서를 OpenSSH에 제공하는 모드이며 인증서만 허용하는 강제 모드는 아니다. 서버 정책에 따라 동일 키의 일반 공개 키 인증도 가능함을 편집 화면에 명시한다. 암호 인증으로는 자동 전환하지 않는다. 저장 비밀번호 자동 사용 시 PreferredAuthentications=password로 제한한다. 실패하면 사용자가 선택한 별도의 수동 인증 시도에서 keyboard-interactive를 허용한다. 설정 따르기는 사용자의 인증 설정을 그대로 이용하며 저장된 서버 비밀번호를 자동 제공하지 않는다.

호스트 키 검증은 StrictHostKeyChecking=ask로 유지한다. 불일치를 자동 무시하거나 known_hosts를 삭제하지 않는다. 앱에서 인증을 받더라도 OpenSSH의 프롬프트 내용을 표시하고 호스트 확인과 비밀번호 입력을 구분한다.

기존 SSH 설정의 ProxyJump 등은 OpenSSH에 맡긴다. 첫 버전의 저장 비밀번호 자동 전달은 직접 연결에 한정한다. 중간 호스트가 존재하는 연결은 저장 비밀번호 자동 제출을 끄고 수동 인증한다. SSH 설정의 ProxyCommand/Match exec는 사용자 코드라는 전제로, 프로필 검증·목록 표시 중에는 실행하지 않는다.

## 인증 도우미 프로토콜

SSH_ASKPASS와 SSH_ASKPASS_REQUIRE=force를 접속 프로세스에만 설정해 PTY가 있어도 도우미를 사용한다. 이 경우 추가 인증을 터미널 입력으로 자동 폴백할 수 있다고 가정하지 않는다. 미분류 프롬프트, OTP, 재시도는 앱의 인증 시트에서 사용자가 직접 입력한다. askpass는 응답만 stdout에 쓰고 취소 시 실패 종료한다.

도우미는 개인 디렉터리의 Unix socket을 통해 앱 broker와 통신한다. 디렉터리 0700, socket 0600, 접속별 난수 capability와 짧은 수명, peer UID/PID 및 서명된 도우미 검증을 조합한다. capability는 자격 증명 자체가 아니며 로그에 기록하지 않는다. IPC 유실·시간 초과·탭 닫기·ssh 종료 시 요청과 capability를 폐기한다. 원격 세션에 인증용 환경 변수를 SendEnv로 전달하지 않는다.

프롬프트 문자열만으로 인증 대상이나 성공 여부를 증명할 수 없다. 자동 사용 시도는 password 방식만 활성화하고 직접 접속의 예상 사용자·호스트에 대한 표준 password 요청만 저장된 서버 비밀번호 자동 응답 대상으로 삼는다. 프롬프트 문자열로 password와 keyboard-interactive 방식을 구분하지 않는다. keyboard-interactive 요청은 매번 사용자가 확인·입력하며 저장 비밀번호를 자동 재사용하지 않는다. 키 암호는 선택한 키 파일과 일치하는 요청만 자동 응답한다. 낯선 요청이나 host 확인 요청에 비밀번호를 반환하지 않는다. 한 시도에서 같은 저장 비밀은 한 번만 제출하고 재요청에는 수동 입력 또는 저장 값 갱신을 제안한다.

위 검증이 macOS 번들 OpenSSH에서 보장되지 않으면 첫 버전부터 저장 값의 명시적 사용 확인 UI로 낮춘다. 임의 프롬프트 자동 응답으로 대체하지 않는다. 메모리 내 비밀 보유 시간을 최소화하되 Swift 문자열의 완전한 zeroization을 보장한다고 주장하지 않는다. 동일 사용자 권한 전체가 탈취된 환경 방어는 보장 범위 밖이다.

## 오류와 인증서 처리

없는 키·인증서 파일은 실행 전에 표시하고 재선택하게 한다. 인증서 만료·principal 불일치·서버 거부는 OpenSSH 결과를 남기고 인증서 갱신 방법을 안내한다. 앱이 인증서를 발급·갱신하거나 CA 키를 보관하지 않는다. 인증서 파일 교체는 다음 접속에 반영한다. 실패 사유를 출력 문자열만으로 확정 분류하지 않는다.

## 범위 밖

SFTP UI, 시리얼·Telnet, PIV/PKCS#11 전용 UI, 인증서 발급·갱신, 클라우드 동기화, 일괄 명령 전송, 자동 로그인 스크립트, SecureCRT 데이터 가져오기, 포트 포워딩 편집 UI. 기존 SSH 설정에 있는 기능은 시스템 SSH가 처리할 수 있다.

## 구현 전 기술 검증과 수용 기준

먼저 macOS에서 PTY + forced askpass + Keychain + 서명된 번들 도우미의 최소 실험으로 비밀번호·키 암호·호스트 확인·OTP·취소를 검증한다. 시스템 SSH 버전별 차이는 지원 macOS 버전의 실제 바이너리로 확인한다. 이 검증이 인증 정책을 충족해야 본 구현으로 진행한다.

- 모델: 원자 저장, 손상·버전 오류, Keychain 갱신 중 실패 복구.
- 실행: 공백·따옴표·셸 특수문자 경로와 입력이 명령 실행으로 해석되지 않음.
- 인증: 비밀번호 로그인, 암호화 키, 유효·만료·잘못된 인증서, 인증서와 동일 키의 일반 공개 키 동작, 암호 방식 자동 전환 차단, OTP, 잘못된 저장 값, Keychain 잠금, 호스트 키 변경.
- 격리: 동시 접속에서 요청 혼선 없음, ProxyJump에 대상 비밀번호 오전달 없음, 취소·탭 닫기·앱 종료 후 도우미 정리.
- UI: 목록 검색·편집·재실행 후 유지, 새 탭·창 생성, 종료 결과·재접속, 복원 후 자동 접속 없음.
- 노출: argv·환경·JSON·진단 로그에 비밀번호/키 암호 없음.

Swift 단위 테스트와 로컬 테스트용 sshd 통합 테스트를 나눠 작성한다. macOS 빌드·테스트는 macos/AGENTS.md에 따라 macos/build.nu를 사용한다. 설계 단계에서는 제품 빌드나 테스트가 필요하지 않다.

## 구현자가 결정할 사항

기존 앱 스타일에 맞는 세부 레이아웃, 충돌 없는 메뉴 단축키, 내부 타입 이름, IPC 직렬화 형식, 지원 macOS 범위에 맞는 Keychain 접근성 속성은 구현자가 결정한다. 인증 방식·비밀 전달 대상·자동 접속 정책 변경은 설계 재검토 대상이다.

## 근거

- 현재 코드: macos/Sources/Features/Terminal/TerminalController.swift, macos/Sources/Ghostty/Surface View/SurfaceView.swift, macos/Sources/Features/App Intents/NewTerminalIntent.swift.
- OpenSSH ssh(1): https://man.openbsd.org/ssh.1 — 인증 도우미 환경과 실행 옵션.
- OpenSSH ssh_config(5): https://man.openbsd.org/ssh_config.5 — 설정 우선순위, IdentityFile/CertificateFile, 인증·호스트 확인 정책. 업스트림 문서는 macOS 탑재 버전 검증을 대신하지 않는다.
