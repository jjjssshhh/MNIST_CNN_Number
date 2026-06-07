`timescale 1ns / 1ps

//============================================================
// uart_tx
// 8N1 UART 송신기 (비동기 시리얼)
// 100MHz 기준 CLKS_PER_BIT=868 → 115200 baud
//
// valid ──► IDLE→START(1bit)→DATA(8bit, LSB first)→STOP(1bit)→IDLE
// ready는 IDLE 상태일 때만 HIGH
//============================================================
module uart_tx #(
    parameter CLKS_PER_BIT = 868  // 100MHz / 115200
)(
    input        clk,
    input  [7:0] data,
    input        valid,
    output       ready,
    output reg   tx
);
    localparam IDLE  = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;

    reg [1:0] state   = IDLE;
    reg [9:0] clk_cnt = 0;
    reg [2:0] bit_idx = 0;
    reg [7:0] shift   = 0;

    assign ready = (state == IDLE);

    always @(posedge clk) begin
        case (state)
            IDLE: begin
                tx <= 1;
                if (valid) begin shift <= data; clk_cnt <= 0; state <= START; end
            end
            START: begin
                tx <= 0;
                if (clk_cnt == CLKS_PER_BIT-1) begin clk_cnt <= 0; bit_idx <= 0; state <= DATA; end
                else clk_cnt <= clk_cnt + 1;
            end
            DATA: begin
                tx <= shift[bit_idx];
                if (clk_cnt == CLKS_PER_BIT-1) begin
                    clk_cnt <= 0;
                    if (bit_idx == 7) state <= STOP;
                    else              bit_idx <= bit_idx + 1;
                end else clk_cnt <= clk_cnt + 1;
            end
            STOP: begin
                tx <= 1;
                if (clk_cnt == CLKS_PER_BIT-1) begin clk_cnt <= 0; state <= IDLE; end
                else clk_cnt <= clk_cnt + 1;
            end
        endcase
    end
endmodule


//============================================================
// line_buffer
// pixel_in 스트림 → 3×3 슬라이딩 윈도우 출력
//
// [동작 흐름]
//  pixel_in (s_valid/s_ready) ──► buffer[3][28] 순환 저장
//                                        │
//                        col >= 2, filled_cnt == 2 조건 충족 시
//                                        ▼
//                               window[0..2][0..2] (9 pixels)
//                               m_valid ──► conv_layer
//
// row[0]=oldest(top), row[2]=newest(bottom) → PyTorch kernel 방향 일치
// frame_rst 시 버퍼 전체 0 초기화 (이전 프레임 잔류 방지)
// s_ready = m_ready 패스스루 → 백프레셔 그대로 상위로 전달
//============================================================
module line_buffer #(
      parameter DATA_WIDTH = 8,
      parameter IMG_WIDTH  = 28
  )(
      input  clk, rstn,
      input  frame_rst,
      // slave
      input  [DATA_WIDTH-1:0] s_data,
      input  s_valid,
      output s_ready,
      // master
      output [DATA_WIDTH-1:0] window[0:2][0:2],
      output logic m_valid,
      input  m_ready
  );

    logic [DATA_WIDTH-1:0] buffer     [0:2][0:IMG_WIDTH-1];
    logic [DATA_WIDTH-1:0] reg_window [0:2][0:2];
    logic reg_valid;

    logic [$clog2(IMG_WIDTH)-1:0] col;
    logic [1:0] row_cnt;
    logic [1:0] filled_cnt;

    // always 블록 평가 시점에는 row_cnt가 아직 갱신 전이므로 pre-NBA 인덱스 별도 계산
    logic [1:0] r1_c, r2_c;
    assign r1_c = (row_cnt == 0) ? 2 : row_cnt - 1;
    assign r2_c = (row_cnt == 1) ? 2 : (row_cnt == 0) ? 1 : 0;

    always @(posedge clk, negedge rstn) begin
        if (!rstn) begin
            col <= 0; row_cnt <= 0; filled_cnt <= 0; reg_valid <= 0;
        end
        else if (frame_rst) begin
            col <= 0; row_cnt <= 0; filled_cnt <= 0; reg_valid <= 0;
            for(int i=0; i<3;i=i+1)begin
                for(int j=0; j<IMG_WIDTH; j=j+1)begin
                    buffer[i][j] <= 0;
                end
            end
        end
        else if (s_valid && s_ready) begin
            buffer[row_cnt][col] <= s_data;

            if (col == IMG_WIDTH-1) begin
                col <= 0;
                row_cnt <= (row_cnt == 2) ? 0 : row_cnt + 1;
                if (filled_cnt < 2) filled_cnt <= filled_cnt + 1;
            end else
                col <= col + 1;

            // col=2~27 범위, 3행이 채워진 시점부터 윈도우 캡처 (col=27 wrap 누락 없음)
            if ((col >= 2) && (filled_cnt == 2)) begin
                reg_window[2][2] <= s_data;
                reg_window[2][1] <= buffer[row_cnt][col-1];
                reg_window[2][0] <= buffer[row_cnt][col-2];

                reg_window[1][2] <= buffer[r1_c][col];
                reg_window[1][1] <= buffer[r1_c][col-1];
                reg_window[1][0] <= buffer[r1_c][col-2];

                reg_window[0][2] <= buffer[r2_c][col];
                reg_window[0][1] <= buffer[r2_c][col-1];
                reg_window[0][0] <= buffer[r2_c][col-2];
                reg_valid <= 1;
            end else
                reg_valid <= 0;
        end else begin
            if (m_ready) reg_valid <= 0;  // m_ready=0이면 valid 홀드 (다운스트림 대기)
        end
    end

    assign window[0][0] = reg_window[0][0];
    assign window[0][1] = reg_window[0][1];
    assign window[0][2] = reg_window[0][2];
    assign window[1][0] = reg_window[1][0];
    assign window[1][1] = reg_window[1][1];
    assign window[1][2] = reg_window[1][2];
    assign window[2][0] = reg_window[2][0];
    assign window[2][1] = reg_window[2][1];
    assign window[2][2] = reg_window[2][2];

    assign m_valid = reg_valid;
    assign s_ready = m_ready;

endmodule


//============================================================
// conv_layer
// 3×3 컨볼루션 (NUM_FILTERS=4, combinational)
//
// [동작 흐름]
//  window[0..2][0..2] (line_buffer 출력)
//          ──► 4개 필터 동시 MAC 계산 (9 multiply-accumulate)
//                     ▼
//          m_data[0..3] (20bit signed) / m_valid ──► relu_layer
//
// pixel(8bit, unsigned) × weight(8bit, signed) × 9항 → 최대 ~291k → 20bit
// {1'b0, pixel}: unsigned 8bit → signed 9bit zero-extend (밝은 픽셀 음수 방지)
// weight 배열: 3D→1D 변환 (weight[n*9 + i*3 + j]), Vivado 합성 제약 회피
//============================================================
module conv_layer #(
        parameter DATA_WIDTH  = 8,
        parameter OUT_WIDTH   = DATA_WIDTH*2+4,
        parameter NUM_FILTERS = 4,
        parameter IMG_WIDTH   = 28
    )(
        input  clk, rstn,
        // slave (line_buffer 출력 받기)
        input  [DATA_WIDTH-1:0] window[0:2][0:2],
        input  s_valid,
        output s_ready,
        // master
        output logic signed [OUT_WIDTH-1:0] m_data [0:NUM_FILTERS-1],
        output m_valid,
        input  m_ready
    );

    logic signed [DATA_WIDTH-1:0] weight [0:NUM_FILTERS*9-1];

    initial begin
        $readmemh("conv1_weight_96_2.mem", weight);
    end

    always_comb begin
        for (int n = 0; n < NUM_FILTERS; n++) begin
            m_data[n] = 0;
            if(s_valid && s_ready) begin
                for (int i = 0; i < 3; i++)
                    for (int j = 0; j < 3; j++)
                        m_data[n] = m_data[n] + $signed({1'b0, window[i][j]}) * $signed(weight[n*9 + i*3 + j]);
            end
        end
    end

    assign m_valid = s_valid && s_ready;
    assign s_ready = m_ready;

endmodule


//============================================================
// relu_layer
// 요소별 ReLU: max(0, x), 레지스터 1사이클 레이턴시
//
// conv_layer m_data ──► ReLU ──► m_data (relu_data) ──► maxpool_layer
//============================================================
module relu_layer #(
        parameter DATA_WIDTH  = 16,
        parameter NUM_FILTERS = 4
    )(
        input  clk, rstn,
        input  frame_rst,
        input  signed [DATA_WIDTH-1:0] s_data [0:NUM_FILTERS-1],
        input  s_valid,
        output s_ready,
        output logic signed [DATA_WIDTH-1:0] m_data [0:NUM_FILTERS-1],
        output logic m_valid,
        input  m_ready
    );

    always@(posedge clk, negedge rstn)begin
    if(!rstn)begin
        for(int i=0; i<NUM_FILTERS; i=i+1)
          m_data[i] <= 0;
    end
    else if(frame_rst)begin
        for(int i=0; i<NUM_FILTERS; i=i+1)
          m_data[i] <= 0;
    end
    else if(s_valid && s_ready)begin
        for(int i=0; i< NUM_FILTERS; i=i+1)begin
            m_data[i] <= (s_data[i] > 0) ? s_data[i] : 0;
        end
    end
    end

    always@(posedge clk, negedge rstn) begin
        if(!rstn) m_valid <= 0;
        else if (frame_rst) m_valid <= 0;
        else if (m_ready) m_valid <= s_valid && s_ready;  // m_ready=0이면 valid 홀드
    end
    assign s_ready = m_ready;

endmodule


//============================================================
// maxpool_layer
// 2×2 Max Pooling (stride 2)
// 26×26×4 → 13×13×4  (INPUT_WIDTH=26)
//
// [동작 흐름]
//  relu_data (s_valid/s_ready) ──► col/row 카운터
//    col 짝수          : horiz_buf 저장
//    col 홀수, row 짝수 : row_buf[col>>1] ← max(horiz_buf, cur)
//    col 홀수, row 홀수 : row_buf와 비교 → m_data 출력
//                                          m_valid ──► fc_layer
//============================================================
module maxpool_layer #(
        parameter DATA_WIDTH  = 16,
        parameter NUM_FILTERS = 4,
        parameter INPUT_WIDTH = 26
    )(
    input clk, rstn,
    input frame_rst,
    input logic signed [DATA_WIDTH-1:0] s_data [0:NUM_FILTERS-1],
    input s_valid,
    output s_ready,
    output logic signed [DATA_WIDTH-1:0] m_data [0:NUM_FILTERS-1],
    output logic m_valid,
    input m_ready
    );

    logic [$clog2(INPUT_WIDTH)-1:0] col;
    logic [$clog2(INPUT_WIDTH)-1:0] row;

    logic signed [DATA_WIDTH-1:0] horiz_buf [0:NUM_FILTERS-1];
    logic signed [DATA_WIDTH-1:0] row_buf [0:NUM_FILTERS-1][0:INPUT_WIDTH/2-1];

    logic signed [DATA_WIDTH-1:0] hmax [0:NUM_FILTERS-1];

    always@(posedge clk, negedge rstn) begin
        if(!rstn) begin
            col <= 0; row <= 0; m_valid <= 0;
        end
        else if(frame_rst) begin
            col <= 0; row <= 0; m_valid <= 0;
        end
        else if(s_valid && s_ready) begin

            if(col == INPUT_WIDTH-1) begin
                col <= 0;
                row <= (row == INPUT_WIDTH-1) ? 0 : row + 1;
            end else
                col <= col + 1;

            if(col[0] == 0) begin
                for(int n=0; n<NUM_FILTERS; n++)
                    horiz_buf[n] <= s_data[n];
                m_valid <= 0;
            end else begin
                if(row[0] == 0) begin
                    for(int n=0; n<NUM_FILTERS; n++)
                        row_buf[n][col>>1] <= (horiz_buf[n] > s_data[n]) ? horiz_buf[n] : s_data[n];
                    m_valid <= 0;
                end else begin
                    for(int n=0; n<NUM_FILTERS; n++) begin
                        hmax[n] = (horiz_buf[n] > s_data[n]) ? horiz_buf[n] : s_data[n];
                        m_data[n] <= (row_buf[n][col>>1] > hmax[n]) ? row_buf[n][col>>1] : hmax[n];
                    end
                    m_valid <= 1;
                end
            end
        end else begin
            if (m_ready) m_valid <= 0;  // m_ready=0이면 valid 홀드
        end
    end

    assign s_ready = m_ready;

endmodule


//============================================================
// fc_layer
// Fully Connected (INPUT_SIZE=676 → OUTPUT_SIZE=10), ACC_WIDTH=40bit
//
// [동작 흐름]
//  pool_data (s_valid) ──► s_data_lat 래치 + w_lat[n=0] 프리패치
//       n_cnt=1..10 사이클: acc[n-1] += w_lat × s_data_lat (4채널 동시)
//       idx == INPUT_SIZE/4-1 도달 → done
//                  ▼
//       m_data[0..9] = acc + bias / m_valid ──► argmax_layer
//
// [타이밍 최적화]
//  병렬 버전: 10출력 동시 계산 → WNS -24.3ns (타이밍 실패)
//  현재(직렬화): n_cnt 카운터로 10사이클 순차 누산 → 타이밍 통과
//  w_lat 프리패치: weight 배열 읽기와 누산을 분리해 critical path 단축
//============================================================
module fc_layer #(
        parameter DATA_WIDTH  = 16,
        parameter NUM_FILTERS = 4,
        parameter INPUT_WIDTH = 26,
        parameter INPUT_SIZE  = ((INPUT_WIDTH/2)**2) * NUM_FILTERS,
        parameter OUTPUT_SIZE = 10,
        parameter ACC_WIDTH   = 40
    )(
        input  clk, rstn,
        input  frame_rst,
        input  logic signed [DATA_WIDTH-1:0] s_data [0:NUM_FILTERS-1],
        input  s_valid,
        output s_ready,
        output logic signed [ACC_WIDTH-1:0] m_data [0:OUTPUT_SIZE-1],
        output logic m_valid,
        input  m_ready
    );
        logic signed [7:0] fc_w [0:OUTPUT_SIZE-1][0:INPUT_SIZE-1];
        logic signed [7:0] bias [0:OUTPUT_SIZE-1];
        logic signed [ACC_WIDTH-1:0]  acc  [0:OUTPUT_SIZE-1];
        logic [$clog2(INPUT_SIZE)-1:0]  idx;
        logic [$clog2(OUTPUT_SIZE)-1:0] n_cnt;
        logic signed [DATA_WIDTH-1:0]   s_data_lat [0:NUM_FILTERS-1];
        logic signed [7:0]              w_lat      [0:NUM_FILTERS-1];
        logic done;

        initial begin
            $readmemh("fc_weight_96_2.mem", fc_w);
            $readmemh("fc_bias_96_2.mem", bias);
        end

        assign s_ready = (n_cnt == 0) && m_ready;

        always @(posedge clk, negedge rstn) begin
            if (!rstn) begin
                idx <= 0; n_cnt <= 0; done <= 0; m_valid <= 0;
                for (int i = 0; i < OUTPUT_SIZE; i++) acc[i] <= 0;
            end
            else if (frame_rst) begin
                idx <= 0; n_cnt <= 0; done <= 0; m_valid <= 0;
                for (int i = 0; i < OUTPUT_SIZE; i++) acc[i] <= 0;
            end
            else begin
                done <= 0; m_valid <= 0;

                if (n_cnt == 0) begin
                    if (s_valid && s_ready) begin
                        for (int k = 0; k < NUM_FILTERS; k++) s_data_lat[k] <= s_data[k];
                        // n=0 웨이트 프리패치: 다음 사이클(n_cnt=1)에서 acc[0] 누산
                        for (int k = 0; k < NUM_FILTERS; k++)
                            w_lat[k] <= fc_w[0][idx*NUM_FILTERS + k];
                        n_cnt <= 1;
                    end
                end else begin
                    acc[n_cnt-1] <= acc[n_cnt-1]
                        + $signed(w_lat[0]) * $signed(s_data_lat[0])
                        + $signed(w_lat[1]) * $signed(s_data_lat[1])
                        + $signed(w_lat[2]) * $signed(s_data_lat[2])
                        + $signed(w_lat[3]) * $signed(s_data_lat[3]);

                    if (n_cnt == OUTPUT_SIZE) begin
                        n_cnt <= 0;
                        if (idx == INPUT_SIZE/NUM_FILTERS - 1) begin idx <= 0; done <= 1; end
                        else idx <= idx + 1;
                    end else begin
                        // 다음 n 웨이트 프리패치
                        for (int k = 0; k < NUM_FILTERS; k++)
                            w_lat[k] <= fc_w[n_cnt][idx*NUM_FILTERS + k];
                        n_cnt <= n_cnt + 1;
                    end
                end

                if (done) begin
                    m_valid <= 1;
                    for (int n = 0; n < OUTPUT_SIZE; n++) begin
                        m_data[n] <= acc[n] + bias[n];
                        acc[n]    <= 0;
                    end
                end
            end
        end

    endmodule


//============================================================
// argmax_layer
// 4단계 토너먼트 트리 파이프라인 (10→5→3→2→1)
//
// [동작 흐름]
//  fc_data[0..9] ──► fc_data_r (파이프라인 레지스터, 라우팅 분리)
//       Stage1: 5쌍 병렬 비교  10→5
//       Stage2: 2쌍 비교+1통과  5→3
//       Stage3: 1쌍 비교+1통과  3→2
//       Stage4: 최종 비교       2→1 ──► result[3:0] + result_valid
//
// [타이밍 최적화]
//  v1 동적 인덱싱: fanout 276, WNS -23ns
//  v2 직렬 체인:  41 logic levels, WNS -11ns
//  현재(트리): ~10 logic levels → 타이밍 통과
//============================================================
module argmax_layer #(
    parameter OUTPUT_SIZE = 10,
    parameter ACC_WIDTH   = 40
)(
    input  clk,
    input  frame_rst,
    input  logic signed [ACC_WIDTH-1:0] s_data [0:OUTPUT_SIZE-1],
    input  s_valid,
    output logic [3:0] result,
    output logic       result_valid
);
    logic signed [ACC_WIDTH-1:0] fc_data_r [0:OUTPUT_SIZE-1];
    logic fc_valid_r;
    always @(posedge clk) begin
        if (frame_rst) fc_valid_r <= 0;
        else           fc_valid_r <= s_valid;
        if (s_valid)
            for (int i = 0; i < OUTPUT_SIZE; i++)
                fc_data_r[i] <= s_data[i];
    end

    // Stage 1: 5쌍 병렬 비교 (10→5)
    logic signed [ACC_WIDTH-1:0] val_s1 [0:4];
    logic [3:0]                  idx_s1 [0:4];
    logic                        vld_s1;
    always @(posedge clk) begin
        vld_s1 <= frame_rst ? 1'b0 : fc_valid_r;
        if (fc_data_r[1] > fc_data_r[0]) begin val_s1[0] <= fc_data_r[1]; idx_s1[0] <= 4'd1; end
        else                              begin val_s1[0] <= fc_data_r[0]; idx_s1[0] <= 4'd0; end
        if (fc_data_r[3] > fc_data_r[2]) begin val_s1[1] <= fc_data_r[3]; idx_s1[1] <= 4'd3; end
        else                              begin val_s1[1] <= fc_data_r[2]; idx_s1[1] <= 4'd2; end
        if (fc_data_r[5] > fc_data_r[4]) begin val_s1[2] <= fc_data_r[5]; idx_s1[2] <= 4'd5; end
        else                              begin val_s1[2] <= fc_data_r[4]; idx_s1[2] <= 4'd4; end
        if (fc_data_r[7] > fc_data_r[6]) begin val_s1[3] <= fc_data_r[7]; idx_s1[3] <= 4'd7; end
        else                              begin val_s1[3] <= fc_data_r[6]; idx_s1[3] <= 4'd6; end
        if (fc_data_r[9] > fc_data_r[8]) begin val_s1[4] <= fc_data_r[9]; idx_s1[4] <= 4'd9; end
        else                              begin val_s1[4] <= fc_data_r[8]; idx_s1[4] <= 4'd8; end
    end

    // Stage 2: 5→3 (2쌍 비교 + 1 통과)
    logic signed [ACC_WIDTH-1:0] val_s2 [0:2];
    logic [3:0]                  idx_s2 [0:2];
    logic                        vld_s2;
    always @(posedge clk) begin
        vld_s2 <= frame_rst ? 1'b0 : vld_s1;
        if (val_s1[1] > val_s1[0]) begin val_s2[0] <= val_s1[1]; idx_s2[0] <= idx_s1[1]; end
        else                        begin val_s2[0] <= val_s1[0]; idx_s2[0] <= idx_s1[0]; end
        if (val_s1[3] > val_s1[2]) begin val_s2[1] <= val_s1[3]; idx_s2[1] <= idx_s1[3]; end
        else                        begin val_s2[1] <= val_s1[2]; idx_s2[1] <= idx_s1[2]; end
        val_s2[2] <= val_s1[4]; idx_s2[2] <= idx_s1[4];
    end

    // Stage 3: 3→2 (1쌍 비교 + 1 통과)
    logic signed [ACC_WIDTH-1:0] val_s3 [0:1];
    logic [3:0]                  idx_s3 [0:1];
    logic                        vld_s3;
    always @(posedge clk) begin
        vld_s3 <= frame_rst ? 1'b0 : vld_s2;
        if (val_s2[1] > val_s2[0]) begin val_s3[0] <= val_s2[1]; idx_s3[0] <= idx_s2[1]; end
        else                        begin val_s3[0] <= val_s2[0]; idx_s3[0] <= idx_s2[0]; end
        val_s3[1] <= val_s2[2]; idx_s3[1] <= idx_s2[2];
    end

    // Stage 4: 2→1 최종
    always @(posedge clk) begin
        if (frame_rst)
            result_valid <= 0;
        else if (vld_s3) begin
            result       <= (val_s3[1] > val_s3[0]) ? idx_s3[1] : idx_s3[0];
            result_valid <= 1;
        end else
            result_valid <= 0;
    end

endmodule


//============================================================
// cnn_top
// CNN 추론 파이프라인 최상위
//
//  pixel_in ──► line_buffer ──► conv_layer ──► relu_layer
//               (3×3 window)   (4 filters)
//                                                  │
//                                                  ▼
//              result ◄── argmax_layer ◄── fc_layer ◄── maxpool_layer
//              result_valid  (4-stage)    (676→10)      (2×2 stride)
//
// valid-ready 핸드쉐이크: 전 계층 s_ready = m_ready 패스스루
// frame_rst: result_valid 시 line_buffer 자동 리셋 (다음 프레임 즉시 수용)
//============================================================
module cnn_top #(
    parameter DATA_WIDTH  = 8,
    parameter NUM_FILTERS = 4,
    parameter IMG_WIDTH   = 28,
    parameter OUTPUT_SIZE = 10,
    parameter ACC_WIDTH   = 40,
    parameter CONV_WIDTH  = DATA_WIDTH*2+4  // 20bit: unsigned 9bit × signed 8bit × 9항
)(
    input  clk, rstn,
    input  frame_rst,
    input  [DATA_WIDTH-1:0] pixel_in,
    input  pixel_valid,
    output pixel_ready,
    output [3:0] result,
    output result_valid
);
    // line_buffer → conv
    wire [DATA_WIDTH-1:0]      lb_window [0:2][0:2];
    wire                       lb_m_valid, lb_m_ready;

    // conv → relu
    (* mark_debug = "true" *) wire signed [CONV_WIDTH-1:0] conv_data [0:NUM_FILTERS-1];
    (* mark_debug = "true" *) wire                         conv_valid, conv_ready;

    // relu → maxpool
    wire signed [CONV_WIDTH-1:0] relu_data [0:NUM_FILTERS-1];
    wire                         relu_valid, relu_ready;

    // maxpool → fc
    wire signed [CONV_WIDTH-1:0] pool_data [0:NUM_FILTERS-1];
    wire                         pool_valid, pool_ready;

    // fc → argmax
    wire signed [ACC_WIDTH-1:0] fc_data [0:OUTPUT_SIZE-1];
    wire                        fc_valid;

    line_buffer #(.DATA_WIDTH(DATA_WIDTH), .IMG_WIDTH(IMG_WIDTH))
    u_lb (
        .clk(clk), .rstn(rstn),
        .frame_rst(result_valid | frame_rst),  // 추론 완료 시 자동 리셋
        .s_data(pixel_in), .s_valid(pixel_valid), .s_ready(pixel_ready),
        .window(lb_window), .m_valid(lb_m_valid), .m_ready(lb_m_ready)
    );

    conv_layer #(.DATA_WIDTH(DATA_WIDTH), .OUT_WIDTH(CONV_WIDTH), .NUM_FILTERS(NUM_FILTERS), .IMG_WIDTH(IMG_WIDTH))
    u_conv (
        .clk(clk), .rstn(rstn),
        .window(lb_window), .s_valid(lb_m_valid), .s_ready(lb_m_ready),
        .m_data(conv_data), .m_valid(conv_valid), .m_ready(conv_ready)
    );

    relu_layer #(.DATA_WIDTH(CONV_WIDTH), .NUM_FILTERS(NUM_FILTERS))
    u_relu (
        .clk(clk), .rstn(rstn), .frame_rst(frame_rst),
        .s_data(conv_data), .s_valid(conv_valid), .s_ready(conv_ready),
        .m_data(relu_data), .m_valid(relu_valid), .m_ready(relu_ready)
    );

    maxpool_layer #(.DATA_WIDTH(CONV_WIDTH), .NUM_FILTERS(NUM_FILTERS), .INPUT_WIDTH(IMG_WIDTH-2))
    u_pool (
        .clk(clk), .rstn(rstn), .frame_rst(frame_rst),
        .s_data(relu_data), .s_valid(relu_valid), .s_ready(relu_ready),
        .m_data(pool_data), .m_valid(pool_valid), .m_ready(pool_ready)
    );

    fc_layer #(.DATA_WIDTH(CONV_WIDTH), .NUM_FILTERS(NUM_FILTERS),
                .INPUT_WIDTH(IMG_WIDTH-2), .OUTPUT_SIZE(OUTPUT_SIZE),
                .ACC_WIDTH(ACC_WIDTH))
    u_fc (
        .clk(clk), .rstn(rstn), .frame_rst(frame_rst),
        .s_data(pool_data), .s_valid(pool_valid), .s_ready(pool_ready),
        .m_data(fc_data), .m_valid(fc_valid), .m_ready(1'b1)
    );

    argmax_layer #(.OUTPUT_SIZE(OUTPUT_SIZE), .ACC_WIDTH(ACC_WIDTH))
    u_argmax (
        .clk(clk), .frame_rst(frame_rst),
        .s_data(fc_data), .s_valid(fc_valid),
        .result(result), .result_valid(result_valid)
    );

endmodule
