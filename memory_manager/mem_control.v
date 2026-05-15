//Note that this is isolated system, assuming only CPU and RAM, no cache

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
    localparam IDLE             = 4'd0;
    localparam WAIT             = 4'd1;  // replaces WAIT_1/2/3/4, WRITE_REROW_WAIT, READ_REROW_WAIT
    localparam WRITE_1          = 4'd2;
    localparam WRITE_2          = 4'd3;
    localparam READ_1           = 4'd4;
    localparam READ_2           = 4'd5;
    localparam COL_FAILSWITCH   = 4'd6;  // replaces WRITE_COL_FAILSWITCH, READ_COL_FAILSWITCH
    localparam REROW            = 4'd7;  // replaces WRITE_REROW, READ_REROW
    localparam DONE             = 4'd8;

    localparam WAITING_TIME = 2'd3;

    reg [3:0] state;
    reg [3:0] next_state;    // tells WAIT where to go when counter expires
    reg [1:0] counter;
    reg [12:0] row;
    reg [9:0] col;
    reg [31:0] tempData;
    reg [14:0] next_bank_row;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            WrEnOut        <= 1'b1;
            DataMask       <= 2'd0;
            RowAddrStrobe  <= 1;
            ColAddrStrobe  <= 1;
            busy           <= 0;
            done           <= 0;
            state          <= IDLE;
            next_state     <= IDLE;
            counter        <= 0;
        end else begin
            case (state)

                IDLE : begin
                    if (EnIn) begin
                        row           <= AddrIn[24:12];
                        BankAddr      <= AddrIn[11:10];
                        col           <= AddrIn[9:0];
                        AddrOut       <= AddrIn[24:12];
                        RowAddrStrobe <= 0;
                        busy          <= 1;
                        done          <= 0;
                        // After RAS wait: branch on WrEnIn
                        if (WrEnIn) begin
                            DataOut    <= WrData[15:0];  // latch low half early
                            next_state <= WRITE_1;
                        end else begin
                            next_state <= READ_1;
                        end
                        state <= WAIT;
                    end else begin
                        busy <= 0;
                        done <= 0;
                    end
                end

                // Single shared wait state: counts to WAITING_TIME then jumps to next_state
                WAIT : begin
                    RowAddrStrobe <= 1;   // deassert RAS if it was pulsed (harmless if already high)
                    ColAddrStrobe <= 1;   // deassert CAS if it was pulsed (harmless if already high)
                    WrEnOut       <= 1;   // deassert WE  if it was pulsed (harmless if already high)
                    if (counter == WAITING_TIME) begin
                        counter <= 0;
                        state   <= next_state;
                    end else begin
                        counter <= counter + 1;
                    end
                end

                WRITE_1 : begin
                    ColAddrStrobe <= 0;
                    WrEnOut       <= 0;
                    AddrOut       <= {3'd0, col};
                    // After CAS wait: advance col, choose next or failswitch
                    if (col == 10'd1023) begin
                        next_state <= COL_FAILSWITCH;
                    end else begin
                        col        <= col + 1;
                        next_state <= WRITE_2;
                    end
                    state <= WAIT;
                end

                WRITE_2 : begin
                    ColAddrStrobe <= 0;
                    WrEnOut       <= 0;
                    AddrOut       <= {3'd0, col};
                    next_state    <= DONE;
                    state         <= WAIT;
                end

                READ_1 : begin
                    ColAddrStrobe <= 0;
                    AddrOut       <= {3'd0, col};
                    // After CAS wait: advance col, choose next or failswitch
                    if (col == 10'd1023) begin
                        next_state <= COL_FAILSWITCH;
                    end else begin
                        col        <= col + 1;
                        next_state <= READ_2;
                    end
                    state <= WAIT;
                end

                READ_2 : begin
                    ColAddrStrobe <= 0;
                    AddrOut       <= {3'd0, col};
                    next_state    <= DONE;
                    state         <= WAIT;
                end

                COL_FAILSWITCH : begin
                    // col wrapped: move to next bank/row, reset col
                    col           <= 10'd0;
                    next_bank_row <= {BankAddr, row} + 1'b1;
                    // Capture the second half for the write path while WrData is still valid
                    if (WrEnIn) DataOut <= WrData[31:16];
                    state <= REROW;
                end

                REROW : begin
                    // Apply incremented bank+row and pulse RAS
                    BankAddr      <= next_bank_row[14:13];
                    row           <= next_bank_row[12:0];
                    AddrOut       <= next_bank_row[12:0];
                    RowAddrStrobe <= 0;
                    // Route back to the correct second-word state after the RAS wait
                    next_state    <= WrEnIn ? WRITE_2 : READ_2;
                    state         <= WAIT;
                end

                DONE : begin
                    // Capture the second half that just came back from RAM (read path)
                    // For the write path this is a no-op since tempData[31:16] was never used
                    tempData[31:16] <= ReDataFromRAM;
                    ReData          <= {ReDataFromRAM, tempData[15:0]};
                    done            <= 1;
                    state           <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule