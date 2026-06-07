# MNIST_CNN_FPGA

TFT 터치 스크린으로 손글씨 숫자를 그리면 FPGA 위의 CNN이 추론하여 결과를 7-세그먼트에 표시하는 프로젝트.  
Python으로 학습한 가중치를 `.mem` 파일로 변환하여 RTL에 직접 탑재했다.

## 구성

| 파일 | 설명 |
|---|---|
| `top_main.sv` | 최상위 모듈, 터치·TFT·CNN·UART 연결 |
| `cnn_top.sv` | CNN 파이프라인 (line_buffer / conv / relu / maxpool / fc / argmax) + uart_tx |
| `cnn_reader.v` | draw_bram → cnn_top 픽셀 스트리밍, 2-FF 토글 동기화 |
| `seg_decoder.v` | 4bit 숫자 → Basys3 7-세그먼트 캐소드 디코더 |
| `tft_lcd_sv.sv` | ILI9341 TFT SPI 드라이버 |
| `constraints.xdc` | Basys3 핀 배치 (클럭 14.29ns, 7-seg, JB/JC Pmod, UART) |
| `tb_top_1000.sv` | 1000장 배치 추론 테스트벤치 (정확도 측정) |
| `tb_top.sv` | 숫자별 단건 추론 테스트벤치 |
| `conv1_weight_96_2.mem` | Conv layer 가중치 (4 filters × 9 = 36 values) |
| `fc_weight_96_2.mem` | FC layer 가중치 (10 × 676 = 6760 values) |
| `fc_bias_96_2.mem` | FC layer 바이어스 (10 values) |
| `img_1000.mem` | MNIST 테스트 이미지 1000장 (28×28 grayscale) |
| `label_1000.mem` | 위 이미지의 정답 레이블 |

## CNN 아키텍처

```
pixel_in (28×28) ──► line_buffer ──► conv_layer ──► relu_layer
                     (3×3 window)   (4 filters)
                                                         │
                     result ◄── argmax_layer ◄── fc_layer ◄── maxpool_layer
                               (4-stage tree)   (676→10)      (2×2 stride)
```

| 계층 | 입력 | 출력 | 비고 |
|---|---|---|---|
| conv (3×3, 4 filters) | 28×28×1 | 26×26×4 | 20bit signed 출력 |
| maxpool (2×2) | 26×26×4 | 13×13×4 = 676 | stride 2 |
| fc | 676 | 10 | 40bit accumulator |
| argmax | 10 | 1 | 4단계 토너먼트 트리 |

## 주요 설계 포인트

- **valid-ready 핸드쉐이크**: 전 계층이 `s_ready = m_ready` 패스스루로 구성, 백프레셔 자동 전파
- **FC 직렬화**: 10출력 병렬 계산 시 WNS -24.3ns → `n_cnt` 카운터로 10사이클 순차 누산으로 타이밍 통과
- **argmax 토너먼트 트리**: 직렬 체인(41 levels, WNS -11ns) 대비 4단계 파이프라인으로 ~10 levels 달성
- **1D 가중치 배열**: Vivado 합성 시 3D `$readmemh` 미적용 문제 → `weight[n*9 + i*3 + j]` 1D 변환으로 해결
- **좌우 반전 보정**: XPT2046 터치 X축이 TFT 스캔 방향과 반대 → `x_flip = 27 - x` 보정 적용
- **UART 디버깅**: btnR 시 draw_bram 784바이트를 PC로 덤프 (115200 baud), 좌우 반전 문제 진단에 활용

## 정확도

| 환경 | 정확도 |
|---|---|
| 시뮬레이션 (1000장) | 95.9% |
| 하드웨어 실측 | 83.3% |

## 개발 환경

- **Tool**: Vivado 2024.2
- **Target Board**: Basys3 (Artix-7 XC7A35T)
- **Simulation**: Vivado Simulator (XSim)

## 시뮬레이션 참고

`$readmemh` 경로가 상대경로로 설정되어 있다.  
Vivado에서 시뮬레이션 실행 전 **Simulation > Simulation Settings > Simulation working directory**를 프로젝트 루트(`.mem` 파일이 있는 위치)로 설정하거나, `cnn_top.sv` / `tb_top_1000.sv`의 경로를 절대경로로 수정한다.
