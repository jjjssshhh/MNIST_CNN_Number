`timescale 1ns / 1ps

module tb_cnn_top;
    parameter DATA_WIDTH = 8;

    logic clk, rstn;
    logic frame_rst_tb;
    logic [DATA_WIDTH-1:0] pixel_in;
    logic pixel_valid, pixel_ready;
    logic [3:0] result;
    logic result_valid;

    cnn_top u_dut (
        .clk(clk), .rstn(rstn),
        .frame_rst(frame_rst_tb),
        .pixel_in(pixel_in),
        .pixel_valid(pixel_valid),
        .pixel_ready(pixel_ready),
        .result(result),
        .result_valid(result_valid)
    );

    always #5 clk = ~clk;

    logic [DATA_WIDTH-1:0] img [0:783];
    integer i, correct, total;
    string path;

    task run_image(input int label);
        $display("[%0t ns] digit %0d 시작", $time/1000, label);
        pixel_valid = 0;
        @(posedge clk);

        for (i = 0; i < 784; i++) begin
            @(posedge clk);
            while (!pixel_ready) @(posedge clk);
            pixel_valid <= 1;
            pixel_in    <= img[i];
        end
        // img[783]: for 루프 마지막 while 탈출 clock에서 img[782]이 소비됨.
        // img[783]은 그 clock의 NBA로 pixel_in에 세팅 → 다음 clock은 n_cnt=1(ready=0)
        // 따라서 clock 하나 먼저 전진 후 다시 ready 대기해야 img[783]이 소비됨.
        @(posedge clk);                        // n_cnt=1..10 구간으로 진입
        while (!pixel_ready) @(posedge clk);   // n_cnt=0 복귀 대기 → 이 clock에서 img[783] 소비
        @(posedge clk);                        // 소비 후 한 클럭 여유
        pixel_valid <= 0;
        $display("[%0t ns] digit %0d 픽셀 전송 완료, 추론 대기중...", $time/1000, label);

        // 타임아웃: 500μs 안에 결과 없으면 상태 덤프
        fork
            wait(result_valid);
            begin
                repeat(50000) @(posedge clk);
                $display("[%0t ns] TIMEOUT - fc.done=%b fc.idx=%0d fc.n_cnt=%0d pool.m_valid=%b relu.m_valid=%b lb.m_valid=%b",
                    $time/1000,
                    u_dut.u_fc.done,
                    u_dut.u_fc.idx,
                    u_dut.u_fc.n_cnt,
                    u_dut.u_pool.m_valid,
                    u_dut.u_relu.m_valid,
                    u_dut.u_lb.m_valid);
                $finish;
            end
        join_any
        disable fork;
        @(posedge clk);

        if (result == label) begin
            $display("digit %0d → 결과: %0d ✓", label, result);
            correct++;
        end else begin
            $display("digit %0d → 결과: %0d ✗ (오답)", label, result);
        end
        total++;
    endtask

    initial begin
        clk = 0; rstn = 0; frame_rst_tb = 0; pixel_valid = 0; pixel_in = 0;
        correct = 0; total = 0;
        path = "./";
        #20;
        rstn = 1;
        #10;

        $readmemh({path, "/mnist_0.mem"}, img); run_image(0);
        $readmemh({path, "/mnist_1.mem"}, img); run_image(1);
        $readmemh({path, "/mnist_2.mem"}, img); run_image(2);
        $readmemh({path, "/mnist_3.mem"}, img); run_image(3);
        $readmemh({path, "/mnist_4.mem"}, img); run_image(4);
        $readmemh({path, "/mnist_5.mem"}, img); run_image(5);
        $readmemh({path, "/mnist_6.mem"}, img); run_image(6);
        $readmemh({path, "/mnist_7.mem"}, img); run_image(7);
        $readmemh({path, "/mnist_8.mem"}, img); run_image(8);
        $readmemh({path, "/mnist_9.mem"}, img); run_image(9);

        $display("─────────────────────────");
        $display("최종: %0d / %0d 정답", correct, total);
        #10000 $finish;
    end
endmodule
