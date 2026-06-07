`timescale 1ns / 1ps

module tb_cnn_top_1000;
    parameter DATA_WIDTH = 8;
    parameter N_IMAGES   = 1000;

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

    // ── 전체 이미지·레이블 배열 ──────────────────────
    logic [7:0] all_imgs   [0:N_IMAGES*784-1];
    logic [3:0] all_labels [0:N_IMAGES-1];

    // ── 통계 ─────────────────────────────────────────
    integer correct, total;
    integer class_correct[0:9];
    integer class_total  [0:9];

    integer i, k;
    logic [7:0] img[0:783];

    // ── 1장 추론 태스크 (기존 TB와 동일) ─────────────
    task run_image(input int label);
        pixel_valid = 0;
        @(posedge clk);

        for (i = 0; i < 784; i++) begin
            @(posedge clk);
            while (!pixel_ready) @(posedge clk);
            pixel_valid <= 1;
            pixel_in    <= img[i];
        end
        @(posedge clk);
        while (!pixel_ready) @(posedge clk);
        @(posedge clk);
        pixel_valid <= 0;
        
        //valid가 뜨거나 timeout이 되거나 
        fork
            wait(result_valid);
            begin
                repeat(50000) @(posedge clk);
                $display("[TIMEOUT] k=%0d label=%0d", total, label);
                $finish;
            end
        join_any
        disable fork;
        @(posedge clk);

        if (result == label) begin
            correct++;
            class_correct[label]++;
        end
        class_total[label]++;
        total++;
    endtask

    // ── 메인 ─────────────────────────────────────────
    initial begin
        clk = 0; rstn = 0; frame_rst_tb = 0;
        pixel_valid = 0; pixel_in = 0;
        correct = 0; total = 0;
        for (i = 0; i < 10; i++) begin
            class_correct[i] = 0;
            class_total[i]   = 0;
        end

        $readmemh("img_1000.mem",   all_imgs);
        $readmemh("label_1000.mem", all_labels);

        #20; rstn = 1; #10;

        for (k = 0; k < N_IMAGES; k++) begin
            // 이미지 슬라이싱
            for (i = 0; i < 784; i++)
                img[i] = all_imgs[k*784 + i];

            // 이미지 간 리셋 펄스
            frame_rst_tb = 1; @(posedge clk); frame_rst_tb = 0;
            @(posedge clk);

            run_image(int'(all_labels[k]));

            if ((k+1) % 100 == 0)
                $display("진행: %0d / %0d  현재 정확도: %.1f%%",
                    k+1, N_IMAGES, real'(correct)*100.0/real'(total));
        end

        // ── 최종 결과 ──────────────────────────────
        $display("══════════════════════════════════");
        $display("총 정확도: %0d / %0d  (%.1f%%)",
            correct, total, real'(correct)*100.0/real'(total));
        $display("──────────────────────────────────");
        for (i = 0; i < 10; i++)
            $display("  숫자 %0d : %0d / %0d  (%.1f%%)",
                i, class_correct[i], class_total[i],
                class_total[i] > 0 ? real'(class_correct[i])*100.0/real'(class_total[i]) : 0.0);
        $display("══════════════════════════════════");

        #1000 $finish;
    end

endmodule
