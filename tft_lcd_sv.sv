`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 02/25/2026 03:44:17 PM
// Design Name: 
// Module Name: tft_lcd_sv
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 02/25/2026 03:19:33 PM
// Design Name: 
// Module Name: tft_lcd
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module spi(
    input clk, reset_p,
    input[8:0] data, 
    input dataAvailable,
    output tft_sck, 
    output reg tft_sdi, tft_dc, 
    output tft_cs,
    output reg idle);

    reg internalSck, cs;
    reg[0:2] counter = 3'b0;
    reg[8:0] internalData;
    wire dataDc = internalData[8];
    wire[0:7] dataShift = internalData[7:0];
    
    assign tft_sck = internalSck & cs;
    assign tft_cs = !cs;
   
    always @ (posedge clk, posedge reset_p) begin
        if(reset_p)begin
            internalSck <= 1'b1;
            idle <= 1'b1;
            cs <= 1'b0;
        end
        else begin
            if (dataAvailable) begin
                internalData <= data;
                idle <= 1'b0;
            end
            if (!idle)begin
                internalSck <= !internalSck;
                if (internalSck) begin
                    tft_dc <= dataDc;
                    tft_sdi <= dataShift[counter];
                    cs <= 1'b1;
                    counter <= counter + 1'b1;
                    if(counter == 7)idle <= 1;
                end
            end
            else begin
                internalSck <= 1'b1;
                if (internalSck) cs <= 1'b0;
            end
        end
    end
		
endmodule

module tft_sv(
		input clk, reset_p,
		input tft_sdo,
		output wire tft_sck,
		output wire tft_sdi,
		output wire tft_dc,
		output reg tft_reset,
		output wire tft_cs,
		input[15:0] framebufferData,
		output wire framebufferClk,
		output reg [17:0] framebufferIndex,
		output reg [9:0] x,
		output wire [9:0] y_out);
		
		parameter INPUT_CLK_MHZ = 100;
		
		reg[8:0] spiData; 
		reg spiDataSet = 1'b0;
		wire spiIdle;
	
		reg frameBufferLowByte;
		assign framebufferClk = !frameBufferLowByte;
		
		initial tft_reset = 1'b1;
		
		spi spi_inst (clk, 1'b0, spiData, spiDataSet, tft_sck, tft_sdi, tft_dc, tft_cs, spiIdle);
		
		parameter INIT_SEQ_LEN = 52;
		
		reg[5:0] initSeqCounter = 6'b0;
		
		reg[8:0] INIT_SEQ [0:INIT_SEQ_LEN-1] = '{
		// Turn off Display
		{1'b0, 8'h28},
		// Init (??)
		{1'b0, 8'hCF}, {1'b1, 8'h00}, {1'b1, 8'h83}, {1'b1, 8'h30}, 
		{1'b0, 8'hED}, {1'b1, 8'h64}, {1'b1, 8'h03}, {1'b1, 8'h12}, {1'b1, 8'h81},
		{1'b0, 8'hE8}, {1'b1, 8'h85}, {1'b1, 8'h01}, {1'b1, 8'h79}, 
		{1'b0, 8'hCB}, {1'b1, 8'h39}, {1'b1, 8'h2C}, {1'b1, 8'h00}, {1'b1, 8'h34}, {1'b1, 8'h02},
		{1'b0, 8'hF7}, {1'b1, 8'h20},
		{1'b0, 8'hEA}, {1'b1, 8'h00}, {1'b1, 8'h00},
		// Power Control
		{1'b0, 8'hC0}, {1'b1, 8'h26},
		{1'b0, 8'hC1}, {1'b1, 8'h11},
		// VCOM
		{1'b0, 8'hC5}, {1'b1, 8'h35}, {1'b1, 8'h3E},
		{1'b0, 8'hC7}, {1'b1, 8'hBE},
		// Memory Access Control
		{1'b0, 8'h3A}, {1'b1, 8'h55},
		// Frame Rate
		{1'b0, 8'hB1}, {1'b1, 8'h00}, {1'b1, 8'h1B},
		// Gamma
		{1'b0, 8'h26}, {1'b1, 8'h01},
		// Brightness
		{1'b0, 8'h51}, {1'b1, 8'hFF},
		// Display
		{1'b0, 8'hB7}, {1'b1, 8'h07},
		{1'b0, 8'hB6}, {1'b1, 8'h0A}, {1'b1, 8'h82}, {1'b1, 8'h27}, {1'b1, 8'h00},
		{1'b0, 8'h29}, // Enable Display
		{1'b0, 8'h2C} // Start  Memory-Write
	};
	
	// ★ 추가됨: 매 프레임마다 강제로 좌표를 (0,0)으로 맞추는 자가 치유 시퀀스
        parameter SYNC_SEQ_LEN = 11;
        reg [3:0] syncCounter = 0;
        reg [8:0] SYNC_SEQ [0:SYNC_SEQ_LEN-1] = '{
            {1'b0, 8'h2A}, {1'b1, 8'h00}, {1'b1, 8'h00}, {1'b1, 8'h00}, {1'b1, 8'hEF}, // X좌표 리셋
            {1'b0, 8'h2B}, {1'b1, 8'h00}, {1'b1, 8'h00}, {1'b1, 8'h01}, {1'b1, 8'h3F}, // Y좌표 리셋
            {1'b0, 8'h2C} // 메모리 쓰기 재시작 명령
        };
		
		reg[23:0] remainingDelayTicks = 24'b0;
		enum logic[2:0] { START, HOLD_RESET, WAIT_FOR_POWERUP, SEND_INIT_SEQ, SYNC_FRAME, LOOP} state = START;
		
        
        reg [9:0] y;
        assign y_out = y;
		always @ (posedge clk, posedge reset_p)begin
		  if(reset_p)begin
		      frameBufferLowByte = 1;
		      x = 0;
		      y = 0;
		      framebufferIndex = 0;
		      state = START;
		      remainingDelayTicks = 0;
		      initSeqCounter = 6'b0;
		  end
		  else begin
			spiDataSet <= 1'b0;
			if (remainingDelayTicks > 0) 
			begin
				remainingDelayTicks <= remainingDelayTicks - 1'b1;
			end
			
			else if (spiIdle && !spiDataSet)
			begin
				case (state)
					START: begin
                        tft_reset <= 1'b0;
                        remainingDelayTicks <= 24'(INPUT_CLK_MHZ * 10); // min: 10us
                        state <= HOLD_RESET;
					end
				
					HOLD_RESET: begin
                        tft_reset <= 1'b1;
                        remainingDelayTicks <= 24'(INPUT_CLK_MHZ * 120000); // min: 120ms
                        state <= WAIT_FOR_POWERUP;
                        frameBufferLowByte <= 1'b0;
					end
				
					WAIT_FOR_POWERUP: begin
                        spiData <= {1'b0, 8'h11}; 
                        spiDataSet <= 1'b1;
                        remainingDelayTicks <= 24'(INPUT_CLK_MHZ * 5000); // min: 5ms
                        state <= SEND_INIT_SEQ;
                        frameBufferLowByte <= 1'b1;
					end
				
					SEND_INIT_SEQ: begin
                        if (initSeqCounter < INIT_SEQ_LEN) begin
                            spiData <= INIT_SEQ[initSeqCounter];
                            spiDataSet <= 1'b1;
                            initSeqCounter <= initSeqCounter + 1'b1;
                        end
                        else begin
                            state <= LOOP;
                            remainingDelayTicks <= 24'(INPUT_CLK_MHZ * 10000); // min: 10ms
                        end
					end
					
					// ★ 추가됨: 노이즈로 밀린 좌표를 강제로 동기화하는 상태
                    SYNC_FRAME: begin
                        if (syncCounter < SYNC_SEQ_LEN) begin
                            spiData <= SYNC_SEQ[syncCounter];
                            spiDataSet <= 1'b1;
                            syncCounter <= syncCounter + 1'b1;
                        end else begin
                            state <= LOOP; // 동기화 완료 후 다시 데이터 전송 시작
                        end
                    end
                    
                    default: begin // LOOP 상태
                        framebufferIndex <= x[9:1] * 320 + y;
                        
                        // 현재 픽셀 데이터 전송 셋팅
                        spiData <= !frameBufferLowByte ? {1'b1, ~framebufferData[15:8]} : {1'b1, ~framebufferData[7:0]};
                        spiDataSet <= 1'b1;
                        frameBufferLowByte <= ~frameBufferLowByte;

                        // 좌표 증가 및 프레임 끝 체크
                        if(x >= 479)begin
                            x <= 0;
                            if(y >= 319) begin
                                y <= 0;
                                // ★ 핵심: 화면을 다 그렸으면 SYNC_FRAME으로 넘어가서 영점 조절
                                state <= SYNC_FRAME;
                                syncCounter <= 0;
                            end
                            else y <= y + 1;
                        end
                        else x <= x + 1;
                    end
				endcase
			 end	
			end
		end
		
endmodule

module lcd_bram
  #(parameter WIDTH = 8,
    parameter DEPTH = 320 * 240)
   (input wclk,
    input wr_en,
    input [16:0] wr_addr,
    
    input rclk,
    input rd_en,
    input [16:0] rd_addr,
    
    input bram_en,
    input [WIDTH-1:0] data_to_ram,
    output reg [WIDTH-1:0] data_from_ram);
    
    
    
    reg [WIDTH-1:0] ram [0:DEPTH];
    
    always @(posedge wclk)
        if(bram_en)
            if(wr_en)
                ram[wr_addr] <= data_to_ram;
                
    always @(posedge rclk)
        if(rd_en)
            data_from_ram <= ram[rd_addr];



endmodule

module xpt2046(
    Clk50m,
    Rst_n,
    EN,
    X_Value,
    Y_Value,
    Get_Flag,
    
    PenIrq_n,
    DCLK,
    DIN,
    DOUT,
    CS_N
    
);

    input Clk50m;
    input Rst_n;
    input EN;
    output reg [11:0]X_Value;
    output reg [11:0]Y_Value;
    
    output reg Get_Flag;
    
    input PenIrq_n;
    
    output reg DCLK;
    output reg DIN;
    output reg CS_N;
    input  DOUT;
    
    wire pen_flag;
    wire pen_state;
    
    reg [4:0]DIV_CNT;       // DCLK를 생성하기 위해 DCLK 클럭의 두 배인 샘플링 클럭을 가져옵니다.
    reg [5:0]CLK_GEN_CNT;   // DCLK 클럭 카운터를 생성합니다.
    reg [5:0]CONV_CNT;      // 완료된 변환 수를 기록합니다.
    
    reg [19:0]PEN_CNT;
    
    reg DCLK2X;
    reg CONV_DONE;
    reg [11:0]Dtmp;
    reg EN_CONV;
    
    reg [16:0]tmp_X_Value,tmp_Y_Value;
    reg [11:0]X_MAX,X_MIN,Y_MAX,Y_MIN;
    reg r_Get_Flag;
    
    localparam S = 1'b1;    //시작 비트 
    localparam MODE = 1'b0; //샘플링 정확도 
    localparam SER_DFR = 1'b0; //단일 종단/차동 샘플링 모드 
    localparam PD = 2'b00;  //전력 소비 제어 
    parameter CONV_TIMES = 36;  // 몇 번의 변환마다 평균값을 계산합니다. 
    parameter FILTER_PARAM = 4; // 16으로 나누기 == 오른쪽으로 4비트 이동
    
    parameter CNT_TOP = 20'd499999; // PEN 핀 신호를 필터링하고 지연합니다.
    
    wire [2:0]ADDR; // 샘플링 채널 제어
    
    assign ADDR = (CONV_CNT[0])?3'b101:3'b001;// CONV_CNT 값이 짝수이면 측정 채널 X를 선택하세요.
    
    wire cnt_full;// PEN 핀 신호 필터 카운터 카운트 풀 플래그
    
    // PEN 핀 지연 필터 카운터는
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        PEN_CNT <= 20'd0;
    else if(!PenIrq_n)begin // 펜이 낮은 수준에 있음 
        if(cnt_full)    // 가득 차면 0으로 반환 
            PEN_CNT <= 20'd0;
        else    // 가득 차 있지 않으면 누적 
            PEN_CNT <= PEN_CNT + 1'b1;
    end else    // 펜이 높은 수준에 있으므로 계산 금지 
        PEN_CNT <= 20'd0;
        
    assign cnt_full = (PEN_CNT == CNT_TOP);
    
    assign pen_state = cnt_full;// PenIrq_n 핀이 낮을 때 카운트가 가득 찰 때마다 pen_state 신호가 생성되어 36 샘플링이 트리거됩니다.

    // 2x DCLK 샘플링 클록 주파수 분할 카운터는   
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        DIV_CNT <= 5'd0;
    else if(EN_CONV)begin
        if(DIV_CNT == 5'd24)
            DIV_CNT <= 5'd0;
        else 
            DIV_CNT <= DIV_CNT + 1'b1;
    end
    else
        DIV_CNT <= 5'd0;
    
    // DCLK 활성화 클록을 2회 생성합니다. 
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        DCLK2X <= 1'b0;
    else if(DIV_CNT == 5'd24)
        DCLK2X <= 1'b1;
    else
        DCLK2X <= 1'b0;

    // 2x DCLK 샘플링 클록을 사용하여 시퀀서의 기본 시퀀스를
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        CLK_GEN_CNT <= 6'b0;
    else if(EN_CONV)begin
        if(DCLK2X)begin
            if(CLK_GEN_CNT == 6'd45)//46까지 세고 나서 16으로 돌아가서 다시 세어보기
                CLK_GEN_CNT <= 6'd16;
            else
                CLK_GEN_CNT <= CLK_GEN_CNT + 1'b1;
        end
    end
    else
        CLK_GEN_CNT <= 6'b0;

    // CLK_GEN_CNT 값에 따라 시퀀스를 제어하고, 제어어를 보내고 샘플링 결과를 
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)begin
        DIN <= 1'b1;
        Dtmp <= 12'd0;
        DCLK <= 1'd0;
        CONV_CNT <= 6'd0;
    end     
    else if(EN_CONV)begin
        if(DCLK2X)begin
            case(CLK_GEN_CNT)
                0:begin DIN <= S; DCLK <= 1'b0; end //첫 번째 변환 시작 비트를 보냅니다 
                1:begin DCLK <= 1'b1; end
                
                2:begin DIN <= ADDR[2]; DCLK <= 1'b0; end   //A2 전송
                3:begin DCLK <= 1'b1; end
                
                4:begin DIN <= ADDR[1]; DCLK <= 1'b0; end   //A1 전송
                5:begin DCLK <= 1'b1; end
                
                6:begin DIN <= ADDR[0]; DCLK <= 1'b0; end   // A0 전송
                7:begin DCLK <= 1'b1; end
                
                8:begin DIN <= MODE; DCLK <= 1'b0; end      // 샘플링 정밀도 설정 비트 전송 
                9:begin DCLK <= 1'b1; end
                
                10:begin DIN <= SER_DFR; DCLK <= 1'b0; end  //ADC 입력 모드 비트 전송 
                11:begin DCLK <= 1'b1;end
                
                12:begin DIN <= PD[1]; DCLK <= 1'b0; end    //전력 소모 제어 비트 PD1 전송
                13:begin DCLK <= 1'b1; end
                
                14:begin DIN <= PD[0]; DCLK <= 1'b0; end    //전력 소모 제어 비트 PD0 전송
                15:begin DCLK <= 1'b1; end
                
                16:begin DIN <= 0; DCLK <= 1'b0; end        //샘플 앤 홀드 회로가 작동할 때까지 기다립니다. 
                17:begin DCLK <= 1'b1; end
                
                18:begin DIN <= 0; DCLK <= 1'b0; end
                19:begin Dtmp[11] <= DOUT; DCLK <= 1'b1; end//11번째 비트 변환 결과 읽기
                
                20:begin DIN <= 0; DCLK <= 1'b0; end
                21:begin Dtmp[10] <= DOUT; DCLK <= 1'b1; end//10번째 비트 변환 결과 읽기
                
                22:begin DIN <= 0; DCLK <= 1'b0; end
                23:begin Dtmp[9] <= DOUT; DCLK <= 1'b1; end//9번째 비트 변환 결과 읽기
                
                24:begin DIN <= 0; DCLK <= 1'b0; end
                25:begin Dtmp[8] <= DOUT;DCLK <= 1'b1; end// 8번째 비트 변환 결과 읽기
                
                26:begin DIN <= 0; DCLK <= 1'b0; end
                27:begin Dtmp[7] <= DOUT; DCLK <= 1'b1; end//7번째 비트 변환 결과 읽기
                
                28:begin DIN <= 0; DCLK <= 1'b0; end
                29:begin Dtmp[6] <= DOUT; DCLK <= 1'b1; end//6번째 비트 변환 결과 읽기
                
                30:begin DIN <= S; DCLK <= 1'b0; end    //다음 변환을 위한 제어어 시작 비트를 전송합니다. 
                31:begin Dtmp[5] <= DOUT; DCLK <= 1'b1; end//변환 결과의 5번째 비트를 읽습니다.
                
                32:begin DIN <= ADDR[2]; DCLK <= 1'b0; end//다음 변환을 위해 A2를 보냅니다.
                33:begin Dtmp[4] <= DOUT; DCLK <= 1'b1; end
                
                34:begin DIN <= ADDR[1]; DCLK <= 1'b0; end//다음 변환을 위해 A1을 보냅니다.
                35:begin Dtmp[3] <= DOUT; DCLK <= 1'b1; end
                
                36:begin DIN <= ADDR[0]; DCLK <= 1'b0; end  //다음 변환을 위해 A0 전송
                37:begin Dtmp[2] <= DOUT; DCLK <= 1'b1; end
                
                38:begin DIN <= MODE; DCLK <= 1'b0; end //다음 변환을 위한 샘플링 정밀도 설정 비트를 보냅니다. 
                39:begin Dtmp[1] <= DOUT; DCLK <= 1'b1; end
                
                40:begin DIN <= SER_DFR; DCLK <= 1'b0; end  //다음 샘플링 ADC 입력 모드 비트 전송 
                41:begin Dtmp[0] <= DOUT; DCLK <= 1'b1; CONV_CNT <= CONV_CNT + 1'b1; end
        
                42:begin DIN <= PD[1]; DCLK <= 1'b0; end// 전력 소모 제어 비트 PD1 전송 
                43:begin DCLK <= 1'b1; end
                
                44:begin DIN <= PD[0]; DCLK <= 1'b0; end//전력 소모 제어 비트 PD0 전송 
                45:begin DCLK <= 1'b1; CONV_DONE <= 1'b1; end   
            endcase
        end else
            CONV_DONE <= 1'b0;
    end else if(!EN_CONV)begin
        CONV_CNT <= 0;
        CONV_DONE <= 1'b0;
    end
    
    // 36개 샘플 중 X 채널의 샘플링 결과를 18번 누적합니다.
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        tmp_X_Value <= 17'd0;
    else if(EN_CONV == 1'b0)
        tmp_X_Value <= 17'd0;
    else if(CONV_DONE && CONV_CNT[0])// 변환이 완료되고 변환 횟수가 홀수이면 변환 결과를 X 임시 레지스터에 누적합니다. 
        tmp_X_Value <= tmp_X_Value + Dtmp;

    // 18 X 채널 샘플의 최대값을 기록합니다.
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        X_MAX <= 12'd0;
    else if(EN_CONV == 1'b0)
        X_MAX <= 12'd0;
    else if(CONV_DONE && CONV_CNT[0])begin//转换完成，转换计数为奇数，判断当前值是否大于已存最大值
        if(Dtmp > X_MAX)
            X_MAX <= Dtmp;
        else
            X_MAX <= X_MAX;
    end
    
    // 18 X 채널 샘플의 최소값을 기록합니다.     
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        X_MIN <= 12'd0;
    else if(EN_CONV == 1'b0)
        X_MIN <= 12'd4095;
    else if(CONV_DONE && CONV_CNT[0])begin//转换完成，转换计数为奇数，判断当前值是否小于已存最小值
        if(Dtmp < X_MIN)
            X_MIN <= Dtmp;
        else
            X_MIN <= X_MIN;
    end
    
    // 36개 샘플 중 18번의 Y 채널 샘플링 결과를 누적합니다.
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        tmp_Y_Value <= 17'd0;
    else if(EN_CONV == 1'b0)
        tmp_Y_Value <= 17'd0;
    else if(CONV_DONE && (!CONV_CNT[0]))// 변환이 완료되고 변환 횟수는 짝수이며 변환 결과는 Y 임시 레지스터에 누적됩니다. 
        tmp_Y_Value <= tmp_Y_Value + Dtmp;
    
    // 18 Y 채널 샘플의 최대값을 기록합니다.
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        Y_MAX <= 12'd0;
    else if(EN_CONV == 1'b0)
        Y_MAX <= 12'd0;
    else if(CONV_DONE && (~CONV_CNT[0]))begin// 변환이 완료되었습니다. 변환 횟수가 홀수입니다. 현재 값이 저장된 최대값보다 큰지 확인합니다. 
        if(Dtmp > Y_MAX)
            Y_MAX <= Dtmp;
        else
            Y_MAX <= Y_MAX;
    end
    
    // 18 Y 채널 샘플의 최소값을 기록합니다.
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        Y_MIN <= 12'd0;
    else if(EN_CONV == 1'b0)
        Y_MIN <= 12'd4095;
    else if(CONV_DONE && (~CONV_CNT[0]))begin// 변환이 완료되었습니다. 변환 횟수가 홀수입니다. 현재 값이 저장된 최소값보다 작은지 확인합니다.
        if(Dtmp < Y_MIN)
            Y_MIN <= Dtmp;
        else
            Y_MIN <= Y_MIN;
    end
    
    //36회 변환을 활성화합니다.
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        EN_CONV <= 1'b0;
    else if(EN)begin
        if(pen_state)
            EN_CONV <= 1'b1;
        else if((CONV_CNT == CONV_TIMES) && CLK_GEN_CNT == 29)// 변환 완료, 15사이클 타이밍 정렬 
            EN_CONV <= 1'b0;
        else
            EN_CONV <= EN_CONV;
    end
    else
        EN_CONV <= 1'b0;

    //
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        r_Get_Flag <= 1'b0;
    else if((CONV_CNT == CONV_TIMES) && CONV_DONE)
            r_Get_Flag <= 1'b1;
    else
        r_Get_Flag <= 1'b0;
        
    always@(posedge Clk50m)
        Get_Flag <= r_Get_Flag;
    
    always@(posedge Clk50m)
        CS_N <= ~EN_CONV;
        
    reg [11:0]r_X_Value,r_Y_Value;
    
    // 현재 Y 평균을 계산합니다. Y 평균 = (누적된 값 18개 - 최대값 - 최소값) / 16
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        r_X_Value <= 12'd0;
    else if(r_Get_Flag)
        r_X_Value <= (tmp_X_Value - X_MAX - X_MIN) >> FILTER_PARAM;
    else
        r_X_Value <= r_X_Value;
    
    // 현재 Y 평균을 계산합니다. Y 평균 = (누적된 값 18개 - 최대값 - 최소값) / 16
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        r_Y_Value <= 12'd0;
    else if(r_Get_Flag)
        r_Y_Value <= (tmp_Y_Value - Y_MAX - Y_MIN) >> FILTER_PARAM;
    else
        r_Y_Value <= r_Y_Value;

    // 마지막 변환 결과를 필터링하기 위해 마지막 X 결과를 출력으로 저장합니다. 마지막 변환 결과에는 보도자료 발표 순간이 포함되어 있으므로 결과가 안정적이지 않습니다. 
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        X_Value <= 12'd0;
    else if(r_Get_Flag)
        X_Value <= r_X_Value;

    // 마지막 변환 결과를 필터링하기 위해 마지막 Y 결과를 출력으로 저장합니다. 마지막 변환 결과에는 보도 자료가 포함된 순간이 포함되어 있으므로 결과가 안정적이지 않습니다.        
    always@(posedge Clk50m or negedge Rst_n)
    if(!Rst_n)
        Y_Value <= 12'd0;
    else if(r_Get_Flag)
        Y_Value <= r_Y_Value;

endmodule







