`timescale 1ns / 1ps
//============================================================
// cnn_reader
// draw_bram(LUTRAM) → cnn_top 픽셀 스트리밍
//
// [동작 흐름]
//  frame_done_tog (btnR 토글, top_main 도메인)
//          ──► 2-FF 동기화 ──► frame_start 펄스 (상승/하강 에지 모두 검출)
//                                      │
//                          상태머신 재시작 (어느 상태에서든 즉시)
//                                      │
//                   ADDR: cnn_raddr 제시 (1사이클 대기)
//                   DATA: cnn_rdata → pixel_in, pixel_valid 발행
//                                      │ valid-ready 핸드쉐이크
//                                      ▼
//                              cnn_top (784 pixels, addr 0→783)
//                                      │ result_valid
//                                      ▼
//                              seg_result 업데이트 (7-seg 표시)
//
// BRAM 읽기 레이턴시 1사이클 → 픽셀당 ADDR→DATA 2사이클
// frame_rst = frame_start (line_buffer 초기화 펄스로 전달)
//============================================================

module cnn_reader (
    input        clk,       // 100MHz
    input        rstn,
    // frame_done 토글 동기화 입력
    input        frame_done_tog,
    // CNN BRAM read port
    output reg [9:0] cnn_raddr,
    input      [7:0] cnn_rdata,
    // cnn_top 인터페이스
    output reg [7:0] pixel_in,
    output reg       pixel_valid,
    input            pixel_ready,
    // cnn_top 결과
    input      [3:0] result,
    input            result_valid,
    // 7-seg 출력
    output reg [3:0] seg_result,
    // line_buffer 리셋 (새 프레임 시작 시 펄스)
    output       frame_rst
);
    // 2-FF 토글 동기화: 토글 값이 바뀔 때마다 frame_start 펄스 1사이클 생성
    reg [1:0] tog_sync;
    reg       tog_prev;
    wire      frame_start = tog_sync[1] ^ tog_prev;
    assign    frame_rst   = frame_start;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            tog_sync <= 0;
            tog_prev <= 0;
        end else begin
            tog_sync <= {tog_sync[0], frame_done_tog};
            tog_prev <= tog_sync[1];
        end
    end

    // 픽셀 피드 상태머신
    localparam IDLE = 2'd0, ADDR = 2'd1, DATA = 2'd2;
    reg [1:0] state;
    reg [9:0] cnt;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state       <= IDLE;
            cnt         <= 0;
            cnn_raddr   <= 0;
            pixel_in    <= 0;
            pixel_valid <= 0;
        end else if (frame_start) begin
            // 새 추론 요청 시 어느 상태에서든 즉시 재시작
            cnt         <= 0;
            cnn_raddr   <= 0;
            pixel_valid <= 0;
            state       <= ADDR;
        end else begin
            case (state)
                IDLE: begin
                    pixel_valid <= 0;
                end
                ADDR: begin
                    // 주소 제시 후 1사이클 대기 (BRAM 읽기 레이턴시)
                    state <= DATA;
                end
                DATA: begin
                    pixel_in    <= cnn_rdata;
                    pixel_valid <= 1;
                    if (pixel_valid && pixel_ready) begin
                        if (cnt == 783) begin
                            pixel_valid <= 0;
                            state       <= IDLE;
                        end else begin
                            cnt         <= cnt + 1;
                            cnn_raddr   <= cnt + 1;
                            pixel_valid <= 0;
                            state       <= ADDR;
                        end
                    end
                end
            endcase
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) seg_result <= 0;
        else if (result_valid) seg_result <= result;
    end

endmodule
