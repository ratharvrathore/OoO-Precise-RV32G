//Memory control for the SDRAM on the De0 Nano Board 
//SDRAM uses 16 bit cells but we have 32 bit lookups on the RV32 ISA so we will build a buffer system of sorts
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
    //We will build an FSM to do this task
    //address line is 13 bits, we will have to send it the row first along with row strobe, and then later the col with column strobe.
    //The bank addresses stay still in the meantime

    //Now we do not have any done signal from the SDRAM chip so I am yet to think about something regarding that

    localparam IDLE = 4'd0, WAIT_1 = 4'd1, WAIT_2 = 4'd2, FIGURE_NEXT_ADDR_1 = 4'd3, WAIT_4 = 4'd4;
    localparam READ_1 = 4'd5, READ_2 = 4'd6, WRITE_1 = 4'd7, WRITE_2 = 4'd8;
    localparam WRITE_COL_FAILSWITCH = 4'd11, READ_COL_FAILSWITCH = 4'd12;
    localparam WAITING_TIME = 2'd3;

    reg [2:0] state;
    reg [1:0] counter;
    reg [12:0] row;
    reg [8:0] col;
    reg [31:0] tempData;

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
                        row <= AddrIn[23:11];
                        BankAddr <= AddrIn[10:9];
                        col <= AddrIn[8:0];
                        AddrOut <= AddrIn[23:11]; //start rolling in the row
                        RowAddrStrobe <= 0;
                        state <= WAIT_1;
                        busy <= 1;
                        done <= 0;
                    end
                    busy <= 0;
                    done <= 0;
                end


                WAIT_1 : begin
                    RowAddrStrobe <= 1;
                    if(counter == WAITING_TIME) begin
                        counter <= 0;
                        if (WrEnIn) begin
                            state <= WRITE_1;
                            DataOut <= WrData[31:16];
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
                    AddrOut <= {7'd0,col};
                    state <= WAIT_2;
                end


                WAIT_2 : begin
                    ColAddrStrobe <= 1;
                    WrEnOut <= 1;
                    if(counter == WAITING_TIME) begin
                        counter <= 0;
                        if (col == 9'd511) begin
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
                    //do something



                end


                WRITE_2 : begin
                    ColAddrStrobe <= 0;
                    WrEnOut <= 0;
                    AddrOut <= {7'd0,col};
                    state <= WAIT_3;
                end


                READ_1 : begin
                    ColAddrStrobe <= 0;
                    AddrOut <= {7'd0,col};
                    state <= WAIT_4;
                end


                WAIT_4 : begin
                    ColAddrStrobe <= 1;
                    if(counter == WAITING_TIME) begin
                        done <= 1;
                        if (col == 9'd511) begin
                            state <= READ_COL_FAILSWITCH;
                        end else begin
                            state <= READ_2;
                            col <= col + 1;
                        end
                        counter <= 0;
                        tempData[31:16] <= ReDataFromRAM;
                    end else begin
                        counter <= counter + 1;
                    end
                end


                READ_COL_FAILSWITCH : begin
                    


                end


                READ_2 : begin
                    ColAddrStrobe <= 0;
                    AddrOut <= {7'd0,col};
                    state <= WAIT_3;
                end


                WAIT_3 : begin
                    ColAddrStrobe <= 1;
                    WrEnOut <= 1;
                    if(counter == WAITING_TIME) begin
                        state <= DONE;
                        counter <= 0;
                        tempData[15:0] <= ReDataFromRAM;
                    end else begin
                        counter <= counter + 1;
                    end
                end
                

                DONE : begin
                    done <= 1;
                    DataOut <= tempData;
                    state <= IDLE;
                end
                default: 
            endcase
        end
    end
endmodule