`timescale 1ns / 1ps
//============================================================
// top_main  (project_Guess_Num_4)
// Basys3 MNIST 손글씨 추론 시스템 최상위
//
// [시스템 데이터 흐름]
//
//  XPT2046 터치 ──────────────────────────────┐
//  (t_x/t_y → grid 좌표 + x_flip 보정)        │ write 0xFF
//                                             ▼
//  ILI9341 TFT ──────────────────► draw_bram (28×28 LUTRAM)
//  (lcd_px/py → grid 좌표, 비동기 읽기)         │
//                               ┌─────────────┴──────────────┐
//                               │ 동기 읽기 (1-cycle lat)     │ 비동기 읽기
//                               ▼                             ▼
//                          cnn_reader                    uart_tx ──► uart_tx_pin
//                               │ pixel_in/pixel_valid        (btnR 시 784B → PC)
//                               ▼
//                           cnn_top  Conv→ReLU→MaxPool→FC→ArgMax
//                               │ result[3:0] / result_valid
//                               ▼
//                          seg_decoder ──► 7-seg (an/seg)
//
// btnC : draw_bram 클리어 + TFT 재초기화
// btnR : CNN 추론 트리거 + UART 덤프 동시 시작
// 클럭 : 단일 도메인, XDC 14.29ns(~70MHz) 제약
//============================================================
module top_main(
    input        clk,

    input        btnC,       // clear + reset
    input        btnR,       // CNN 추론

    // TFT ILI9341 SPI
    input        tft_sdo,
    output       tft_sck,
    output       tft_sdi,
    output       tft_dc,
    output       tft_reset,
    output       tft_cs,

    // XPT2046 터치 SPI
    input        PenIrq_n,
    output       DCLK,
    output       DIN,
    output       CS_N,
    input        DOUT,

    // Basys3 7-seg (active-low)
    output [3:0] an,
    output [6:0] seg,

    // UART TX (PC로 28×28 픽셀 덤프)
    output       uart_tx_pin
);

    assign an = 4'b1110;  // 첫 번째 자리만 켜기

    //----------------------------------------------------------
    // 1. 파워온 리셋 (약 10ms)
    //    btnC는 드로잉 클리어만 담당 → TFT 재초기화 없음
    //----------------------------------------------------------
    reg [20:0] por_cnt = 0;
    wire       por     = (por_cnt < 21'd1_000_000);
    always @(posedge clk)
        if (por) por_cnt <= por_cnt + 1;

    wire reset_p     = por;
    wire rstn        = ~por;
    wire tft_rst_p   = por || btnC_sync[1]; // TFT 리셋: 파워온 + btnC

    // btnC 에지 검출 (클리어 트리거)
    reg [1:0] btnC_sync = 0;
    always @(posedge clk)
        btnC_sync <= {btnC_sync[0], btnC};
    wire btnC_pedge = (btnC_sync == 2'b01);

    //----------------------------------------------------------
    // 2. 50MHz 클럭 (XPT2046 입력)
    //----------------------------------------------------------
    reg Clk50M = 0;
    always @(posedge clk) Clk50M <= ~Clk50M;

    //----------------------------------------------------------
    // 3. draw_bram (28×28 = 784 × 8bit, LUTRAM)
    //    drawn pixel = 0xFF, background = 0x00  (MNIST 포맷)
    //
    //    쓰기 우선순위: 클리어 FSM > 터치 입력
    //    읽기 포트 3개 공유: TFT(비동기), CNN(동기), UART(비동기)
    //----------------------------------------------------------
    (* ram_style = "distributed" *) reg [7:0] draw_bram [0:783];

    // 클리어 FSM: reset_p 또는 btnC 시 0x00으로 순차 기입 (784 사이클)
    reg [9:0] clear_cnt = 0;
    reg       clearing  = 0;

    // 터치 → 그리드 좌표
    wire       in_box_touch;
    wire [4:0] grid_x_touch, grid_y_touch;
    // 터치 X축이 TFT 스캔 방향과 반대 → 27에서 빼서 좌우 반전 보정
    wire [4:0] grid_x_touch_flip = 5'd27 - grid_x_touch;
    wire [9:0] touch_wr_addr = ({5'b0, grid_y_touch} * 10'd28)
                             + {5'b0, grid_x_touch_flip};

    // Get_Flag 2-FF 동기화 + 상승 에지 검출 (50MHz → 100MHz 도메인)
    // 매 클럭 쓰기 → 샘플링 완료 시에만 쓰기로 변경 (노이즈 픽셀 감소)
    reg [1:0] get_flag_sync = 0;
    always @(posedge clk)
        get_flag_sync <= {get_flag_sync[0], Get_Flag};
    wire get_flag_pedge = (get_flag_sync == 2'b01);

    always @(posedge clk) begin
        if (reset_p || btnC_pedge) begin
            clear_cnt <= 0;
            clearing  <= 1;
        end else if (clearing) begin
            draw_bram[clear_cnt] <= 8'h00;
            if (clear_cnt == 783) clearing <= 0;
            else                  clear_cnt <= clear_cnt + 1;
        end else if (get_flag_pedge && ~PenIrq_n && in_box_touch && !inferring) begin
             draw_bram[touch_wr_addr] <= 8'hFF;
        end
    end

    //----------------------------------------------------------
    // 4. TFT 좌표 (tft_sv에서 직접 수신)
    //----------------------------------------------------------
    wire [9:0] x_tft;
    wire [9:0] y_tft;

    //----------------------------------------------------------
    // 5. TFT 디스플레이 매핑
    //    28×28 → 224×224 (8배 확대), 240×320 화면 중앙 배치
    //    가로 여백 8px, 세로 여백 48px
    //
    //    draw_bram ──(비동기 읽기)──► display_data ──► tft_sv
    //----------------------------------------------------------
    wire [7:0] lcd_px = x_tft[9:1];
    wire [8:0] lcd_py = y_tft[8:0];

    wire in_box_lcd = (lcd_px >= 8 && lcd_px < 232 &&
                       lcd_py >= 48 && lcd_py < 272);

    wire [4:0] grid_x_lcd = (lcd_px - 8'd8)  >> 3;
    wire [4:0] grid_y_lcd = (lcd_py - 9'd48) >> 3;

    // TFT 표시도 동일한 방향으로 반전 (터치와 일치)
    wire [4:0] grid_x_lcd_flip = 5'd27 - grid_x_lcd;
    wire [9:0] rd_addr_tft = in_box_lcd
        ? (({5'b0, grid_y_lcd} * 10'd28) + {5'b0, grid_x_lcd_flip})
        : 10'd0;

    wire [7:0] display_data = in_box_lcd ? draw_bram[rd_addr_tft] : 8'h20;

    wire framebufferClk;
    wire [17:0] framebufferIndex;

    tft_sv lcd(
        .clk(clk),           .reset_p(tft_rst_p),
        .tft_sdo(tft_sdo),
        .tft_sck(tft_sck),   .tft_sdi(tft_sdi),
        .tft_dc(tft_dc),     .tft_reset(tft_reset),  .tft_cs(tft_cs),
        .framebufferData({8'b0, display_data}),
        .framebufferClk(framebufferClk),
        .framebufferIndex(framebufferIndex),
        .x(x_tft),
        .y_out(y_tft)
    );

    //----------------------------------------------------------
    // 6. XPT2046 터치 캘리브레이션
    //    원시 ADC(0~4095) → 화면 좌표(0~239, 0~319) 변환
    //----------------------------------------------------------
    wire [11:0] X_Value, Y_Value;
    wire        Get_Flag;

    xpt2046 touch_pad(
        .Clk50m(Clk50M), .Rst_n(rstn), .EN(1'b1),
        .X_Value(X_Value), .Y_Value(Y_Value), .Get_Flag(Get_Flag),
        .PenIrq_n(PenIrq_n),
        .DCLK(DCLK), .DIN(DIN), .DOUT(DOUT), .CS_N(CS_N)
    );

    wire [11:0] x_tmp = (X_Value > 12'd300) ? X_Value - 12'd300 : 12'd0;
    wire [11:0] y_tmp = (Y_Value > 12'd300) ? Y_Value - 12'd300 : 12'd0;

    wire [15:0] touch_x_raw = ((x_tmp * 32'd70) >> 10);
    wire [15:0] touch_y_320 = ((y_tmp * 32'd94) >> 10);
    wire [15:0] touch_y_raw = (16'd319 > touch_y_320)
                              ? (16'd319 - touch_y_320) : 16'd0;

    wire [15:0] t_x = (touch_x_raw > 239) ? 16'd239 : touch_x_raw;
    wire [15:0] t_y = (touch_y_raw > 319) ? 16'd319 : touch_y_raw;

    assign in_box_touch  = (t_x >= 8  && t_x < 232 &&
                            t_y >= 48 && t_y < 272);
    assign grid_x_touch  = (t_x - 8'd8)  >> 3;
    assign grid_y_touch  = (t_y - 9'd48) >> 3;

    //----------------------------------------------------------
    // 7. draw_bram → cnn_reader 동기 읽기 포트 (1사이클 레이턴시)
    //
    //    draw_bram ──(sync, cnn_raddr)──► cnn_rdata ──► cnn_reader
    //----------------------------------------------------------
    wire [9:0] cnn_raddr;
    reg  [7:0] cnn_rdata;
    always @(posedge clk)
        cnn_rdata <= draw_bram[cnn_raddr];

    //----------------------------------------------------------
    // 8. btnR 디바운스 + 에지 검출
    //    10ms 안정 확인 후 infer_tog 토글 → cnn_reader 트리거
    //----------------------------------------------------------
    reg [1:0]  btnR_sync   = 0;
    reg [19:0] btnR_cnt    = 0;
    reg        btnR_stable = 0;
    reg        btnR_prev   = 0;

    always @(posedge clk) begin
        btnR_sync <= {btnR_sync[0], btnR};

        if (btnR_sync[1] == btnR_stable) begin
            btnR_cnt <= 0;
        end else if (btnR_cnt == 20'd699_999) begin
            btnR_stable <= btnR_sync[1];
            btnR_cnt    <= 0;
        end else begin
            btnR_cnt <= btnR_cnt + 1;
        end

        btnR_prev <= btnR_stable;
    end

    wire btnR_pedge = btnR_stable & ~btnR_prev;

    reg infer_tog = 0;
    always @(posedge clk) begin
        if (reset_p)         infer_tog <= 0;
        else if (btnR_pedge) infer_tog <= ~infer_tog;
    end

    // 추론 중 draw_bram 쓰기 차단 (터치 입력이 CNN 입력을 오염시키지 않도록)
    reg inferring = 0;
    always @(posedge clk) begin
        if (reset_p)           inferring <= 0;
        else if (btnR_pedge)   inferring <= 1;
        else if (result_valid) inferring <= 0;
    end

    //----------------------------------------------------------
    // 9. CNN 파이프라인 인스턴스
    //
    //    cnn_reader ──(pixel_in/valid/ready)──► cnn_top
    //                                              │ result[3:0]/result_valid
    //                                              ▼
    //                                         seg_decoder ──► seg
    //----------------------------------------------------------
    wire [7:0] pixel_in;
    wire       pixel_valid, pixel_ready;
    wire [3:0] cnn_result;
    wire       result_valid;
    wire [3:0] seg_result;
    wire       cnn_frame_rst;

    cnn_reader reader0(
        .clk(clk),               .rstn(rstn),
        .frame_done_tog(infer_tog),
        .cnn_raddr(cnn_raddr),   .cnn_rdata(cnn_rdata),
        .pixel_in(pixel_in),     .pixel_valid(pixel_valid),
        .pixel_ready(pixel_ready),
        .result(cnn_result),     .result_valid(result_valid),
        .seg_result(seg_result), .frame_rst(cnn_frame_rst)
    );

    cnn_top u_cnn(
        .clk(clk),      .rstn(rstn),
        .frame_rst(cnn_frame_rst),
        .pixel_in(pixel_in),
        .pixel_valid(pixel_valid), .pixel_ready(pixel_ready),
        .result(cnn_result),       .result_valid(result_valid)
    );

    seg_decoder seg0(
        .digit(seg_result),
        .seg(seg)
    );

    //----------------------------------------------------------
    // 10. UART 덤프
    //     draw_bram ──(async, dump_addr)──► uart_tx ──► uart_tx_pin
    //     btnR 상승 엣지 시 784바이트 순차 전송 (115200 baud)
    //----------------------------------------------------------
    localparam DS_IDLE = 2'd0, DS_READ = 2'd1, DS_WAIT = 2'd2;

    reg [1:0] ds        = DS_IDLE;
    reg [9:0] dump_addr = 0;
    reg [7:0] uart_din  = 0;
    reg       uart_vld  = 0;
    wire      uart_rdy;

    wire [7:0] dump_rdata = draw_bram[dump_addr];

    always @(posedge clk) begin
        uart_vld <= 0;
        if (reset_p) begin
            ds <= DS_IDLE; dump_addr <= 0;
        end else case (ds)
            DS_IDLE: begin
                if (btnR_pedge) begin dump_addr <= 0; ds <= DS_READ; end
            end
            DS_READ: begin
                uart_din <= dump_rdata;
                ds <= DS_WAIT;
            end
            DS_WAIT: begin
                if (uart_rdy) begin
                    uart_vld <= 1;
                    if (dump_addr == 783) ds <= DS_IDLE;
                    else begin dump_addr <= dump_addr + 1; ds <= DS_READ; end
                end
            end
        endcase
    end

    uart_tx u_uart (
        .clk(clk), .data(uart_din), .valid(uart_vld),
        .ready(uart_rdy), .tx(uart_tx_pin)
    );

endmodule
