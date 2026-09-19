# Nook 2.0 소스 복원 및 검증

2026-09-07 복원 완료. 이 폴더는 사용자가 지정한 `../Verified-Nook-2.0/Nook.app`을 정확히 재현하는 소스 프로젝트이다.

## 발견한 원인

- `Verified-Nook-2.0`은 당초 ZIP에서 실행 앱만 추출한 폴더로, Sources를 포함하지 않았다. 원래 소스 위치는 `../NotchMusicSource`였다.
- 이후 2.1 작업에서 해당 소스의 `NotchPanelController.swift`가 수정되었고, 버전을 올리기 전에 빌드하면서 `NotchMusicSource/dist/2.0` 및 `Nook-2.0.zip`에 다른 결과가 기록되었다.
- `Verified-Nook-2.1-Project`는 변경된 NotchMusicSource의 소스를 복사한 폴더다. BUILD-INFO의 '기준: Verified-Nook-2.0' 문구는 원본 재현 검증을 의미하지 않는다.
- 조사 시점 최상위 Git 저장소에는 커밋이 없었다.

## 복원 방법

NotchMusicSource의 Sources, Resources, scripts, tests, Package.swift, 변경 내역과 README를 복사했다. 2026-09-07 17:42 작업 기록에 남아 있는 NotchPanelController.swift 변경을 역으로 적용해 `pulseForImmersiveTransition`의 2.0 구현을 복원했다. Info.plist는 기준 앱의 원본을 사용했다. 다른 기존 폴더와 기준 앱은 변경하지 않았다.

근거 작업 기록: `01a07a2c-7564-7552-8e58-c3ce337c83dd`(최초 2.0 빌드 및 해시), `01a07b08-de64-7743-b418-555541ed06c3`(이후 수정 및 복사 기록).

## 검증 결과

`zsh scripts/build-app.sh` 성공. 앱과 ZIP 생성, 패키징 과정의 서명 검증 성공.

기준 앱과 재빌드 앱의 실행 파일 SHA-256 모두:

`c66494e279c183ad04e790589c3dd3bdd2428e5e601ac2ee7eb86c0645782a69`

`diff -qr ../Verified-Nook-2.0/Nook.app dist/2.0/Nook.app` 결과 차이 없음. 실행 파일, Info.plist, 리소스, 서명 파일을 포함한 전체 앱 파일이 바이트 단위로 일치한다. 앱을 새로 실행하거나 설치하지 않았다.

## 위치

- 소스: `Sources/NotchMusic/`
- 리소스: `Resources/`
- 테스트: `tests/`
- 빌드: `zsh scripts/build-app.sh`
- 재현된 앱: `dist/2.0/Nook.app`
- 재현된 배포 ZIP: `dist/Nook-2.0.zip`

기존 README의 오래된 출력 경로 예시 대신 이 문서의 경로를 사용한다. 이후 업데이트는 별도 버전 작업폴더로 복사하여 진행한다.
