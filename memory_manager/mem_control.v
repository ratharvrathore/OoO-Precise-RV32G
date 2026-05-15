//Memory control for the SDRAM on the De0 Nano Board 
//SDRAM uses 16 bit cells but we have 32 bit lookups on the RV32 ISA so we will build a buffer system of sorts

//This version made the following changes from the prev:
//made col 10 bits instead of 9
//accidently made it big endian instead of little
//busy and done flag fixes

module mem_control (
    input wire clk,
    input wire reset, //active high
    input wire [31:0] AddrIn,
    input wire EnIn, //active high memory CPU access enable
    input wire WrEnIn, //active high write enable
    input wire [31:0] WrData,
    input wire [15:0] ReDataFromRAM,

    output reg [31:0] ReData,
    output reg WrEnOut, //active low
    output reg [12:0] AddrOut,
    output reg [1:0] BankAddr,
    output reg [15:0] DataOut, 
    output reg [1:0] DataMask, //active low
    output reg RowAddrStrobe, //active low
    output reg ColAddrStrobe, //active low
    output reg busy, //to CPU, active high
    output reg done, //to CPU, active high
);
    localparam IDLE = 4'd0, WAIT_1 = 4'd1, WAIT_2 = 4'd2, FIGURE_NEXT_ADDR_1 = 4'd3, WAIT_4 = 4'd4;
    localparam READ_1 = 4'd5, READ_2 = 4'd6, WRITE_1 = 4'd7, WRITE_2 = 4'd8;
    localparam WRITE_COL_FAILSWITCH = 4'd11, READ_COL_FAILSWITCH = 4'd12;
    localparam WAITING_TIME = 2'd3;

    localparam WRITE_REROW = 4'd9, WRITE_REROW_WAIT = 4'd10;
    localparam READ_REROW  = 4'd13, READ_REROW_WAIT  = 4'd14;

    reg [3:0] state;
    reg [1:0] counter;
    reg [12:0] row;
    reg [9:0] col;           // Point 1: widened from 9 to 10 bits
    reg [31:0] tempData;

    reg [14:0] next_bank_row;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            WrEnOut <= 1'b1;
            DataMask <= 2'd0;
            RowAddrStrobe <= 1;
            ColAddrStrobe <= 1;
            busy <= 0;
            done <= 0;
            state <= 0;
            counter <= 0;
        end else begin
            case (state)
                IDLE : begin
                    if (EnIn) begin
                        row <= AddrIn[24:12];        // Point 1: adjusted slice
                        BankAddr <= AddrIn[11:10];   // Point 1: adjusted slice
                        col <= AddrIn[9:0];          // Point 1: adjusted slice, now 10 bits
                        AddrOut <= AddrIn[24:12];    // Point 1: adjusted slice
                        RowAddrStrobe <= 0;
                        state <= WAIT_1;
                        busy <= 1;
                        done <= 0;
                    end else begin                   // Point 3: moved into else
                        busy <= 0;
                        done <= 0;
                    end
                end


                WAIT_1 : begin
                    RowAddrStrobe <= 1;
                    if(counter == WAITING_TIME) begin
                        counter <= 0;
                        if (WrEnIn) begin
                            state <= WRITE_1;
                            DataOut <= WrData[15:0];  // Point 2: low half first
                        end else begin
                            state <= READ_1;
                        end
                    end else begin
                        counter <= counter + 1;
                    end
                end


                WRITE_1 : begin
                    ColAddrStrobe <= 0;
                    WrEnOut <= 0;
                    AddrOut <= {3'd0, col};           // Point 1: adjusted mask
                    state <= WAIT_2;
                end


                WAIT_2 : begin
                    ColAddrStrobe <= 1;
                    WrEnOut <= 1;
                    if(counter == WAITING_TIME) begin
                        counter <= 0;
                        if (col == 10'd1023) begin    // Point 1: adjusted overflow check
                            state <= WRITE_COL_FAILSWITCH;
                        end else begin
                            state <= WRITE_2;
                            col <= col + 1;
                        end
                    end else begin
                        counter <= counter + 1;
                    end
                end


                WRITE_COL_FAILSWITCH : begin
                    col <= 10'd0;
                    next_bank_row <= {BankAddr, row} + 1'b1;
                    DataOut <= WrData[31:16];         // Point 2: high half second
                    state <= WRITE_REROW;
                end

                WRITE_REROW : begin
                    BankAddr  <= next_bank_row[14:13];
                    row       <= next_bank_row[12:0];
                    AddrOut   <= next_bank_row[12:0];
                    RowAddrStrobe <= 0;
                    state <= WRITE_REROW_WAIT;
                end

                WRITE_REROW_WAIT : begin
                    RowAddrStrobe <= 1;
                    if (counter == WAITING_TIME) begin
                        counter <= 0;
                        state <= WRITE_2;
                    end else begin
                        counter <= counter + 1;
                    end
                end


                WRITE_2 : begin
                    ColAddrStrobe <= 0;
                    WrEnOut <= 0;
                    AddrOut <= {3'd0, col};           // Point 1: adjusted mask
                    state <= WAIT_3;
                end


                READ_1 : begin
                    ColAddrStrobe <= 0;
                    AddrOut <= {3'd0, col};           // Point 1: adjusted mask
                    state <= WAIT_4;
                end


                WAIT_4 : begin
                    ColAddrStrobe <= 1;
                    if(counter == WAITING_TIME) begin
                        if (col == 10'd1023) begin    // Point 1: adjusted overflow check
                            state <= READ_COL_FAILSWITCH;
                        end else begin
                            state <= READ_2;
                            col <= col + 1;
                        end
                        counter <= 0;
                        tempData[15:0] <= ReDataFromRAM;  // Point 2: low half first, Point 5: done removed
                    end else begin
                        counter <= counter + 1;
                    end
                end


                READ_COL_FAILSWITCH : begin
                    col <= 10'd0;
                    next_bank_row <= {BankAddr, row} + 1'b1;
                    state <= READ_REROW;
                end

                READ_REROW : begin
                    BankAddr  <= next_bank_row[14:13];
                    row       <= next_bank_row[12:0];
                    AddrOut   <= next_bank_row[12:0];
                    RowAddrStrobe <= 0;
                    state <= READ_REROW_WAIT;
                end

                READ_REROW_WAIT : begin
                    RowAddrStrobe <= 1;
                    if (counter == WAITING_TIME) begin
                        counter <= 0;
                        state <= READ_2;
                    end else begin
                        counter <= counter + 1;
                    end
                end


                READ_2 : begin
                    ColAddrStrobe <= 0;
                    AddrOut <= {3'd0, col};           // Point 1: adjusted mask
                    state <= WAIT_3;
                end


                WAIT_3 : begin
                    ColAddrStrobe <= 1;
                    WrEnOut <= 1;
                    if(counter == WAITING_TIME) begin
                        state <= DONE;
                        counter <= 0;
                        tempData[31:16] <= ReDataFromRAM;  // Point 2: high half second
                    end else begin
                        counter <= counter + 1;
                    end
                end
                

                DONE : begin
                    done <= 1;
                    ReData <= tempData;               // Point 7: was DataOut, now ReData
                    state <= IDLE;
                end
                default: 
            endcase
        end
    end
endmodule