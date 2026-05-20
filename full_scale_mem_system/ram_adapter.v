// =============================================================================
// mem_control.v  —  original SDRAM controller (unchanged from provided code)
// =============================================================================
// (kept here verbatim so the project has a single source of truth)

module mem_control (
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] AddrIn,
    input  wire        EnIn,
    input  wire        WrEnIn,
    input  wire [31:0] WrData,
    input  wire [15:0] ReDataFromRAM,

    output reg  [31:0] ReData,
    output reg         WrEnOut,
    output reg  [12:0] AddrOut,
    output reg  [1:0]  BankAddr,
    output reg  [15:0] DataOut,
    output reg  [1:0]  DataMask,
    output reg         RowAddrStrobe,
    output reg         ColAddrStrobe,
    output reg         busy,
    output reg         done
);
    localparam IDLE           = 4'd0;
    localparam WAIT           = 4'd1;
    localparam WRITE_1        = 4'd2;
    localparam WRITE_2        = 4'd3;
    localparam READ_1         = 4'd4;
    localparam READ_2         = 4'd5;
    localparam COL_FAILSWITCH = 4'd6;
    localparam REROW          = 4'd7;
    localparam DONE           = 4'd8;

    localparam WAITING_TIME   = 2'd3;

    reg [3:0] state, next_state;
    reg [1:0] counter;
    reg [12:0] row;
    reg [9:0]  col;
    reg [31:0] tempData;
    reg [14:0] next_bank_row;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            WrEnOut       <= 1'b1;
            DataMask      <= 2'd0;
            RowAddrStrobe <= 1;
            ColAddrStrobe <= 1;
            busy          <= 0;
            done          <= 0;
            state         <= IDLE;
            next_state    <= IDLE;
            counter       <= 0;
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
                        if (WrEnIn) begin
                            DataOut    <= WrData[15:0];
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
                WAIT : begin
                    RowAddrStrobe <= 1;
                    ColAddrStrobe <= 1;
                    WrEnOut       <= 1;
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
                    col           <= 10'd0;
                    next_bank_row <= {row, BankAddr} + 1'b1;
                    if (WrEnIn) DataOut <= WrData[31:16];
                    state <= REROW;
                end
                REROW : begin
                    BankAddr      <= next_bank_row[1:0];
                    row           <= next_bank_row[14:2];
                    AddrOut       <= next_bank_row[14:2];
                    RowAddrStrobe <= 0;
                    next_state    <= WrEnIn ? WRITE_2 : READ_2;
                    state         <= WAIT;
                end
                DONE : begin
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


// =============================================================================
// ram_adapter.v  —  Bridges L2's simple word-level interface to mem_control
// =============================================================================
// L2 presents: addr (32-bit), en, wr_en, wr_data (32-bit) → rd_data, busy, done
// mem_control expects the same signals under different names.
// This is a thin pass-through adapter; it also holds the SDRAM I/O pins.
// =============================================================================

module ram_adapter (
    input  wire        clk,
    input  wire        reset,

    // --- L2 interface ---
    input  wire [31:0] l2_addr,
    input  wire        l2_en,
    input  wire        l2_wr_en,
    input  wire [31:0] l2_wr_data,
    output wire [31:0] l2_rd_data,
    output wire        l2_busy,
    output wire        l2_done,

    // --- Physical SDRAM pins (to top-level) ---
    output wire        sdram_wr_en_n,     // WrEnOut from mem_control (active low)
    output wire [12:0] sdram_addr,        // AddrOut
    output wire [1:0]  sdram_bank,        // BankAddr
    output wire [15:0] sdram_data_out,    // DataOut
    output wire [1:0]  sdram_data_mask,   // DataMask
    output wire        sdram_ras_n,       // RowAddrStrobe
    output wire        sdram_cas_n,       // ColAddrStrobe
    input  wire [15:0] sdram_data_in      // ReDataFromRAM
);
    wire [31:0] mc_redata;
    wire        mc_wrout;
    wire [12:0] mc_addrout;
    wire [1:0]  mc_bankaddr;
    wire [15:0] mc_dataout;
    wire [1:0]  mc_datamask;
    wire        mc_ras, mc_cas;
    wire        mc_busy, mc_done;

    mem_control u_mem_ctrl (
        .clk            (clk),
        .reset          (reset),
        .AddrIn         (l2_addr),
        .EnIn           (l2_en),
        .WrEnIn         (l2_wr_en),
        .WrData         (l2_wr_data),
        .ReDataFromRAM  (sdram_data_in),
        .ReData         (mc_redata),
        .WrEnOut        (mc_wrout),
        .AddrOut        (mc_addrout),
        .BankAddr       (mc_bankaddr),
        .DataOut        (mc_dataout),
        .DataMask       (mc_datamask),
        .RowAddrStrobe  (mc_ras),
        .ColAddrStrobe  (mc_cas),
        .busy           (mc_busy),
        .done           (mc_done)
    );

    assign l2_rd_data      = mc_redata;
    assign l2_busy         = mc_busy;
    assign l2_done         = mc_done;
    assign sdram_wr_en_n   = mc_wrout;
    assign sdram_addr      = mc_addrout;
    assign sdram_bank      = mc_bankaddr;
    assign sdram_data_out  = mc_dataout;
    assign sdram_data_mask = mc_datamask;
    assign sdram_ras_n     = mc_ras;
    assign sdram_cas_n     = mc_cas;

endmodule
