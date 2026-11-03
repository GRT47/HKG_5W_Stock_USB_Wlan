# HKG Gen5W Stock Wi-Fi Hotspot Enabler (USB WLAN -> `wlan0`)

현대·기아 표준형 5세대 와이드 내비게이션(**Standard-class Gen5W**, Telechips `tcc803x` / `tcc897x`, Linux `3.18.24-tcc`, Android 4.4.2) 중 **내장 Wi-Fi 칩이 없는 차량(빌트인 캠 미적용 사양 등)** 에 **USB 무선랜카드(RTL8812BU / RTL8822BU / RTL8831BU / RTL8851BU)** 를 연결하여 **100% 순정 내비게이션의 `[설정 -> 기기 연결 -> Wi-Fi 핫스팟]` 화면 및 안드로이드 순정 `WifiManager` API(`CarrotBridge` 등)** 로 순정 Wi-Fi 핫스팟을 그대로 사용할 수 있게 해주는 독립형 NEMESIS 패키지(`stock.hotspot`)입니다.

---

## 주요 특징

- **100% 순정 Wi-Fi 핫스팟 설정 UI (`HKMC_WifiSettings`) 및 순정 `[설정 -> 데이터/네트워크]` 메뉴 완벽 연동**
  - 순정 설정(`com.android.settings`) 메인 화면에 숨겨져 있던 **`[데이터/네트워크]`** 메뉴 아이콘을 기존의 `Kia Connect` 아이콘과 함께 활성화하여, 내비게이션 순정 **`[설정 -> 데이터/네트워크 -> Wi-Fi 핫스팟]`** 경로로 바로 진입할 수 있습니다.
  - 별도의 외부 오버레이 UI 없이 순정 내비게이션의 **`Wi-Fi 핫스팟`** 메뉴에서 핫스팟 ON/OFF, 네트워크 이름(SSID), 비밀번호, 보안 방식을 순정 그대로 설정하고 제어합니다.
  - 안드로이드 프레임워크 표준 `WifiManager.setWifiApEnabled()` API로 동작하므로 **`CarrotBridge`의 `핫스팟 자동 켜기` 및 원격 제어**와도 100% 호환됩니다.
- **내장 Wi-Fi 유무 자동 판별 및 안전 가드**
  - **내장 Wi-Fi 탑재 차량 (예: 니로 EV 등 SDIO `mmc1:0001` Broadcom `BCM4359` 실장 보드)**: 내장 SDIO Wi-Fi 칩을 자동 감지하여 USB 드라이버를 로드하지 않고 순정 내장 `wlan0` 핫스팟만 활성화합니다.
  - **내장 Wi-Fi 미탑재 차량 (예: EV6, 아이오닉 5, K8 HEV 등 빌트인 캠 미적용 `BT:2` 보드)**:
    1. **`[permanent]` `bcmdhd` 더미 스텁 모듈(`bcmdhd_stub.ko`) 로드**: 안드로이드 `libhardware_legacy.so`의 `is_wifi_driver_loaded()`가 `/proc/modules`에서 `bcmdhd`를 즉시 확인하도록 하여, 존재하지 않는 내장 SDIO 칩 초기화를 시도하다 실패(`-ENODEV`)하거나 핫스팟 종료 시 모듈을 언로드하는 문제를 원천 차단합니다.
    2. **USB 무선랜카드 `wlan0` 바인딩**: Realtek USB 무선랜카드 드라이버(`88x2bu.ko` / `8851bu.ko`)를 순정 인터페이스 이름인 **`wlan0`** 및 표준 DHCP 포트(`UDP 67/68`)로 로드하여 순정 `netd`(`SoftapController`), `/system/bin/hostapd`, `/system/bin/dnsmasq`가 직접 제어하도록 연결합니다.
- **안드로이드 `Tethering` (`192.168.0.1/24`) 서브넷 충돌 자동 정리 및 라우팅**
  - 미사용 내부 이더넷(`eth0: 192.168.0.123/24`)의 서브넷 충돌을 자동으로 정리하여, 순정 `ConnectivityService` / `Tethering`이 `wlan0`(`192.168.0.1/24`)에 연결된 클라이언트들과 정상적으로 통신하도록 구성합니다.
- **커널 패닉 및 재부팅 방지 보호 패치**
  - **Telechips AOA 프로빙 차단 (`dev.devt |= 0x00080000U`)**: 차량 USB 호스트 데몬이 USB 무선랜카드에 Android Open Accessory 제어 요청(`Request 51/52/53`)을 보내 버스가 리셋되는 현상을 커널 레벨에서 차단합니다.
  - **`/system/bin/wl` `SIOCETHTOOL` NULL 역참조 방지**: 핫스팟 활성화 시 순정 `netd`가 호출하는 `/system/bin/wl country KR` 명령이 `SIOCETHTOOL`(`ETHTOOL_GDRVINFO`)을 호출할 때 `wiphy->dev.parent` NULL 역참조로 커널 패닉이 발생하지 않도록 `rtw_ethtool_get_drvinfo` 안전 가드를 적용했습니다.
  - **안전한 USB 핫플러그(Hot-unplug)**: 핫스팟 동작 중 USB 동글이 분리되더라도 커널 패닉 없이 즉시 세션을 정리합니다.

---

## 지원 차량 및 하드웨어

### 지원 차량 (Standard Gen5W)
| 플랫폼 SoC | 커널 버전 | 대표 차종 | 사용 커널 모듈 |
| :--- | :--- | :--- | :--- |
| Telechips `tcc803x` | `3.18.24-tcc` (`SMP preempt mod_unload ARMv7 p2v8`) | EV6, 아이오닉 5, K8 HEV 등 | `88x2bu.ko`, `8851bu.ko`, `bcmdhd_stub.ko` |
| Telechips `tcc897x` | `3.18.24-tcc` (`SMP preempt mod_unload ARMv7 p2v8`) | 니로 EV (DE22EV) 등 | `88x2bu_tcc897x.ko`, `8851bu_tcc897x.ko`, `bcmdhd_stub_tcc897x.ko` |

### 지원 USB 무선랜카드 칩셋
1. **Realtek RTL8812BU / RTL8822BU (AC1200 / AC1300 듀얼밴드)** — USB ID `0bda:b812` 외 다수
2. **Realtek RTL8831BU / RTL8851BU (AX900 Wi-Fi 6 듀얼밴드)** — USB ID `0bda:b831`, `0bda:b851`, TP-Link `2357:010b` / `2357:0142` 등 (가상 CD-ROM `0bda:1a2b` 자동 모드스위치 내장)

> **주의**: 기존 `HKG_5W_USB_Wlan` (`usbwifi.hotspot`, `rtwlan0` 사용) 패키지가 설치되어 있다면 먼저 NEMESIS 대시보드에서 삭제한 뒤 본 패키지(`stock.hotspot`)를 설치해 주세요.

---

## 설치 및 사용 방법

### 1. USB를 통한 설치
1. 패키지 빌드 후 생성되는 `HKG_5W_Stock_Hotspot.zip`의 압축을 **FAT32로 포맷된 USB 메모리 최상단(루트)** 에 풀어줍니다.
   - USB 루트에 `NEMESIS.data` 파일과 `packages/stock.hotspot.zip` 파일이 위치해야 합니다.
2. 차량 USB 포트에 메모리를 꽂으면 NEMESIS 설치 팝업이 표시되며, 설치 완료 후 백그라운드 서비스(`stock-hotspot`)가 자동으로 실행됩니다.
3. *(참고)* 이미 이전 버전의 `stock.hotspot`이 설치되어 있는 경우, NEMESIS 대시보드에서 기존 `Stock WiFi Hotspot Enabler`를 먼저 **Uninstall(삭제)** 한 뒤 USB를 꽂아 설치하세요.

### 2. 순정 Wi-Fi 핫스팟 사용 방법
1. 차량 USB 포트(또는 USB 허브)에 지원되는 USB 무선랜카드를 꽂습니다.
2. 순정 내비게이션 화면에서 **`[설정 -> 데이터/네트워크 -> Wi-Fi 핫스팟]`** 으로 이동합니다.
   - 또는 NEMESIS 대시보드에서 **`Stock WiFi Hotspot Enabler` -> `[Launch]`** 를 누르면 순정 Wi-Fi 핫스팟 설정 화면이 바로 열립니다.
3. **`Wi-Fi 핫스팟 사용`** 체크박스를 켜면 순정 핫스팟이 활성화됩니다.

---

## 저장소 구조 및 빌드 방법

```text
├── package_stock_hotspot/
│   ├── build_package.py               # 커널 모듈 패치/심볼 검증 및 NEMESIS 설치 패키지(HKG_5W_Stock_Hotspot.zip) 생성
│   └── kernel_build/
│       ├── setup_build_env.sh         # Linux 3.18.24-tcc + GCC 4.7 크로스 컴파일 환경 구성 스크립트
│       ├── build_both_ko.sh           # 88x2bu / 8851bu (tcc803x & tcc897x) 4종 커널 모듈 패치 및 빌드
│       ├── config_tcc803x.txt         # tcc803x (EV6, 아이오닉 5, K8 HEV) 커널 설정
│       └── config_tcc897x.txt         # tcc897x (니로 EV) 커널 설정
├── .gitattributes
├── .gitignore
└── README.md
```

### 패키지 빌드 명령
```bash
# 1. (최초 1회 또는 드라이버 소스 재빌드 시) WSL 환경에서 커널 모듈 4종 빌드
wsl sh -c "sh package_stock_hotspot/kernel_build/setup_build_env.sh && sh package_stock_hotspot/kernel_build/build_both_ko.sh"

# 2. 커널 모듈 검증 및 NEMESIS 설치 ZIP (HKG_5W_Stock_Hotspot.zip) 생성
python package_stock_hotspot/build_package.py
```

