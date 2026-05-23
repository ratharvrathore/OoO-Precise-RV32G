module l1_cache (
    input  wire        clk,
    input  wire        reset,

    // CPU interface
    input  wire [31:0] cpu_addr,
    input  wire        cpu_en,
    input  wire        cpu_wr_en,
    input  wire [31:0] cpu_wr_data,
    output reg  [31:0] cpu_rd_data,
    output reg         busy,
    output reg         done,

    inout  wire [31:0] l1_l2_bus,

    output reg         l1_req,       // L1 is requesting a line from L2
    output reg         l1_req_wr,    // 1 = write-miss  0 = read-miss
    output reg  [31:0] l1_req_addr,
    output reg         l1_evict_valid,

    input  wire        l2_busy,
    input  wire        l2_done
);

    localparam SETS      = 32;
    localparam WAYS      = 2;
    localparam LINE_BITS = 128;   // 16 bytes per line

    localparam TAG_W = 23;
    localparam IDX_W = 5;
    localparam OFF_W = 4;

    reg [TAG_W-1:0]    tag   [0:SETS-1][0:WAYS-1];
    reg [LINE_BITS-1:0] data [0:SETS-1][0:WAYS-1];
    reg                valid [0:SETS-1][0:WAYS-1];
    reg                dirty [0:SETS-1][0:WAYS-1];
    reg                lru   [0:SETS-1];

    reg  [31:0] req_addr;
    reg         req_wr_en;
    reg  [31:0] req_wr_data;

    wire [TAG_W-1:0] req_tag  = req_addr[31:9];
    wire [IDX_W-1:0] req_set  = req_addr[8:4];
    wire [OFF_W-1:0] req_off  = req_addr[3:0];
    wire [1:0]       req_woff = req_addr[3:2];   // 32-bit word offset

    wire hit0     = valid[req_set][0] && (tag[req_set][0] == req_tag);
    wire hit1     = valid[req_set][1] && (tag[req_set][1] == req_tag);
    wire hit      = hit0 | hit1;
    wire hit_way  = hit1 ? 1'b1 : 1'b0;

    wire evict_way   = lru[req_set];
    wire evict_dirty = valid[req_set][evict_way] && dirty[req_set][evict_way];

    localparam ST_IDLE            = 3'd0;
    localparam ST_EVALUATE        = 3'd1;   // decode hit/miss; set up L2 req
    localparam ST_HIT_WRITE       = 3'd2;   // 1-cycle: apply write to hit line
    localparam ST_TRANSFER        = 3'd3;   // simultaneous evict↑ / fetch↓
    localparam ST_FILL            = 3'd4;   // install fetched line; latch rd_data
    localparam ST_WRITE_L2_REQ_A  = 3'd5;   // write-miss: wait for L2 ready
    localparam ST_WRITE_L2_REQ_B  = 3'd6;   // write-miss: send word, wait l2_done
    localparam ST_DONE            = 3'd7;   // assert done for one cycle → IDLE

    reg [2:0] state;

    reg [2:0] beat;

    reg [LINE_BITS-1:0] fetch_buf;
    reg [LINE_BITS-1:0] evict_buf;

    reg [31:0] bus_drive;     // what L1 puts on the bus
    reg        bus_drive_en;  // 1 = L1 is driving the bus

    // Tri-state driver
    assign l1_l2_bus = bus_drive_en ? bus_drive : 32'bz;

    integer i, j;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            busy           <= 1'b0;
            done           <= 1'b0;
            l1_req         <= 1'b0;
            l1_req_wr      <= 1'b0;
            l1_req_addr    <= 32'd0;
            l1_evict_valid <= 1'b0;
            bus_drive      <= 32'd0;
            bus_drive_en   <= 1'b0;
            cpu_rd_data    <= 32'd0;
            beat           <= 3'd0;
            state          <= ST_IDLE;
            fetch_buf      <= 128'd0;
            evict_buf      <= 128'd0;
            req_addr       <= 32'd0;
            req_wr_en      <= 1'b0;
            req_wr_data    <= 32'd0;
            for (i = 0; i < SETS; i = i + 1) begin
                lru[i] <= 1'b0;
                for (j = 0; j < WAYS; j = j + 1) begin
                    valid[i][j] <= 1'b0;
                    dirty[i][j] <= 1'b0;
                end
            end
        end else begin
            case (state)
                ST_IDLE : begin
                    done           <= 1'b0;
                    l1_evict_valid <= 1'b0;
                    bus_drive_en   <= 1'b0;
                    if (cpu_en) begin
                        req_addr    <= cpu_addr;
                        req_wr_en   <= cpu_wr_en;
                        req_wr_data <= cpu_wr_data;
                        busy        <= 1'b1;
                        state       <= ST_EVALUATE;
                    end else begin
                        busy <= 1'b0;
                    end
                end

                ST_EVALUATE : begin
                    if (hit) begin
                        if (req_wr_en) begin
                            state <= ST_HIT_WRITE;
                        end else begin
                            cpu_rd_data  <= data[req_set][hit_way][req_woff*32 +: 32];
                            lru[req_set] <= ~hit_way;
                            state        <= ST_DONE;
                        end
                    end else begin
                        if (req_wr_en) begin
                            l1_req      <= 1'b1;
                            l1_req_wr   <= 1'b1;
                            l1_req_addr <= {req_addr[31:4], 4'd0};
                            state       <= ST_WRITE_L2_REQ_A;
                        end else begin
                            l1_evict_valid <= evict_dirty;
                            if (evict_dirty) begin
                                evict_buf <= data[req_set][evict_way];
                            end else begin
                                evict_buf <= 128'd0;
                            end
                            l1_req      <= 1'b1;
                            l1_req_wr   <= 1'b0;
                            l1_req_addr <= {req_addr[31:4], 4'd0};
                            if (!l2_busy) begin
                                beat  <= 3'd0;
                                state <= ST_TRANSFER;
                            end
                        end
                    end
                end

                ST_HIT_WRITE : begin
                    data[req_set][hit_way][req_woff*32 +: 32] <= req_wr_data;
                    dirty[req_set][hit_way] <= 1'b1;
                    lru[req_set]            <= ~hit_way;
                    state <= ST_DONE;
                end

                ST_TRANSFER : begin
                    l1_req <= 1'b0;   // de-assert request after L2 accepts it

                    if (evict_dirty) begin
                        bus_drive_en <= 1'b1;
                        case (beat)
                            3'd0 : begin
                                bus_drive[15:0]    <= evict_buf[15:0];
                                fetch_buf[15:0]    <= l1_l2_bus[31:16];
                            end
                            3'd1 : begin
                                bus_drive[15:0]    <= evict_buf[31:16];
                                fetch_buf[31:16]   <= l1_l2_bus[31:16];
                            end
                            3'd2 : begin
                                bus_drive[15:0]    <= evict_buf[47:32];
                                fetch_buf[47:32]   <= l1_l2_bus[31:16];
                            end
                            3'd3 : begin
                                bus_drive[15:0]    <= evict_buf[63:48];
                                fetch_buf[63:48]   <= l1_l2_bus[31:16];
                            end
                            3'd4 : begin
                                bus_drive[15:0]    <= evict_buf[79:64];
                                fetch_buf[79:64]   <= l1_l2_bus[31:16];
                            end
                            3'd5 : begin
                                bus_drive[15:0]    <= evict_buf[95:80];
                                fetch_buf[95:80]   <= l1_l2_bus[31:16];
                            end
                            3'd6 : begin
                                bus_drive[15:0]    <= evict_buf[111:96];
                                fetch_buf[111:96]  <= l1_l2_bus[31:16];
                            end
                            3'd7 : begin
                                bus_drive[15:0]    <= evict_buf[127:112];
                                fetch_buf[127:112] <= l1_l2_bus[31:16];
                            end
                            default: ;
                        endcase

                        if (beat == 3'd7) begin
                            beat         <= 3'd0;
                            bus_drive_en <= 1'b0;
                            state        <= ST_FILL;
                        end else begin
                            beat <= beat + 1'd1;
                        end

                    end else begin
                        bus_drive_en <= 1'b0;

                        case (beat[1:0])
                            2'd0 : fetch_buf[31:0]   <= l1_l2_bus;
                            2'd1 : fetch_buf[63:32]  <= l1_l2_bus;
                            2'd2 : fetch_buf[95:64]  <= l1_l2_bus;
                            2'd3 : fetch_buf[127:96] <= l1_l2_bus;
                            default: ;
                        endcase

                        if (beat[1:0] == 2'd3) begin
                            beat  <= 3'd0;
                            state <= ST_FILL;
                        end else begin
                            beat <= beat + 1'd1;
                        end
                    end
                end

                ST_FILL : begin
                    data [req_set][evict_way] <= fetch_buf;
                    tag  [req_set][evict_way] <= req_tag;
                    valid[req_set][evict_way] <= 1'b1;
                    dirty[req_set][evict_way] <= 1'b0;
                    lru  [req_set]            <= ~evict_way;
                    cpu_rd_data               <= fetch_buf[req_woff*32 +: 32];
                    state                     <= ST_DONE;
                end

                ST_WRITE_L2_REQ_A : begin
                    if (!l2_busy) begin
                        l1_req <= 1'b0;
                        // Drive the full 32-bit word onto the bus
                        bus_drive    <= req_wr_data;
                        bus_drive_en <= 1'b1;
                        state        <= ST_WRITE_L2_REQ_B;
                    end
                end

                ST_WRITE_L2_REQ_B : begin
                    if (l2_done) begin
                        bus_drive_en <= 1'b0;
                        state        <= ST_DONE;
                    end
                end

                ST_DONE : begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule