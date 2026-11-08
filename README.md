# Tadak

macOS 메뉴 막대에 머물면서, 키보드를 치거나 마우스를 누를 때마다 기계식 키보드·마우스 클릭 소리를 내 주는 앱이에요.

## 설치

터미널에 한 줄만 붙여 넣으세요. (macOS 14 이상, Apple 실리콘·Intel 모두 지원)

```sh
curl -fsSL https://raw.githubusercontent.com/E-JIWON/tadak/main/install.sh | sh
```

처음 실행하면 **손쉬운 사용** 권한을 요청해요. 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 Tadak을 켜면 돼요. 키 입력은 소리를 내는 데만 쓰고, 어떤 키를 눌렀는지 저장하거나 밖으로 보내지 않아요.

업데이트도 같은 명령이에요. 업데이트 뒤 소리가 안 나면 손쉬운 사용에서 Tadak을 껐다 다시 켜 주세요.

[릴리스](https://github.com/E-JIWON/tadak/releases/latest)에서 `Tadak.zip`을 브라우저로 직접 받으면, Apple 공증을 받지 않은 앱이라 처음 열 때 macOS가 막아요. 그때는 시스템 설정 > 개인정보 보호 및 보안에서 "그래도 열기"를 누르세요.

직접 빌드하려면 Xcode 명령줄 도구를 설치하고 `./build.sh`를 실행하세요.

## 소리

| 키보드 | 바탕 |
|---|---|
| 보글 | Rainy 75 (알루미늄) |
| 내 키보드 | Durock T1 Silent Shrimp 67g, 윤활, 알루미늄 바디 |
| 해피해킹 | HHKB (Topre 45g) |
| 북극여우 | Kailh Arctic Fox |
| Box Jade | Kailh Box Jade |
| 멜로딕 | Gateron Melodic |

마우스: 기본(딸깍), 저소음(톡), 게이밍(짤깍), 묵직(딸각), 트랙패드(툭)

메뉴 막대 아이콘을 누르면 나오는 패널에서 소리에 마우스를 올리면 미리 들을 수 있어요.

## 소리 출처

앱에 들어가는 녹음은 모두 [Freesound](https://freesound.org)의 **CC0(퍼블릭 도메인)** 녹음이거나 작성자가 직접 녹음한 거예요.

| 폴더 | 원본 |
|---|---|
| `sounds/rainy75` | [Typing on a rainy 75](https://freesound.org/s/815614/) — Techrul |
| `sounds/boxjade` | [Kailh Box Jade Switches Sound](https://freesound.org/s/643558/) — el_boss |
| `sounds/hhkb` | [Keyboard Typing 7 (HHKB, Topre)](https://freesound.org/s/546164/) — grcekh |
| `sounds/mouse-logitech` | [Mouse Click](https://freesound.org/s/583087/) — IRF1010N |
| `sounds/mouse-razer` | [mouse click (double click) - razer deathadder essential](https://freesound.org/s/555394/) — Katsuhira |
| `sounds/trackpad` | [Mac Book Pro Track Pad Click](https://freesound.org/s/118206/) — MegaPenguin13 |
| `sounds/mykeyboard` | 작성자 녹음 |

`ref/`에는 소리를 맞출 때 비교한 Freesound CC0 녹음 원본이 있어요(목록: `ref/SOURCES.txt`).
멜로딕과 북극여우는 Box Jade 녹음을 다듬어 만든 소리예요.
해피해킹은 녹음에서 고른 타건을 `tools/shape.js`로 다듬은 소리예요(설정은 `sounds/hhkb/SOURCE.txt`).

## 상표

Kailh, Gateron, Durock, Rainy 75, HHKB, Topre, Logitech, Razer, MacBook 등 제품 이름은 각 소유자의 상표예요. 이 프로젝트는 그 회사들과 관련이 없고, 이름은 어떤 소리인지 설명하려고만 써요.

## 라이선스

코드와 작성자가 만든 파일은 [MIT](LICENSE)예요. Freesound 녹음은 CC0예요. 아이콘(`icons/`)은 [Phosphor Icons](https://phosphoricons.com) (MIT)예요.
