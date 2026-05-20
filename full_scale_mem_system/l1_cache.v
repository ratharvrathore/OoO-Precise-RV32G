module l1_cache (
    input  wire        clk,
    input  wire        reset,

    input  wire [31:0] cpu_addr,
    input  wire        cpu_en, //CPU is issuing a request this cycle
    input  wire        cpu_wr_en, //active high
    input  wire [31:0] cpu_wr_data,
    output reg  [31:0] cpu_rd_data,
    output reg         busy,
    output reg         done,

    output reg  [15:0] l1_to_l2_data,
    input  wire [15:0] l2_to_l1_data,

    output reg         l1_req, //L1 is requesting a line from L2
    output reg         l1_req_wr,
    output reg  [31:0] l1_req_addr,
    output reg         l1_evict_valid,

    input  wire        l2_busy,
    input  wire        l2_done
);

    localparam SETS      = 32;
    localparam WAYS      = 2;// 2 way set associative
    localparam LINE_BITS = 128; // 16 bytes

    localparam TAG_W     = 23;
    localparam IDX_W     = 5;
    localparam OFF_W     = 4;

    reg [TAG_W-1:0]    tag   [0:SETS-1][0:WAYS-1];
    reg [LINE_BITS-1:0] data [0:SETS-1][0:WAYS-1];
    reg                valid [0:SETS-1][0:WAYS-1];
    reg                dirty [0:SETS-1][0:WAYS-1];
    reg                lru   [0:SETS-1];  //Which Way is the LRU??


    reg  [31:0] req_addr;// We will sample the address from the CPU wire line
    reg         req_wr_en;
    reg  [31:0] req_wr_data;

    wire [TAG_W-1:0] req_tag  = req_addr[31:9];
    wire [IDX_W-1:0] req_set  = req_addr[8:4];
    wire [OFF_W-1:0] req_off  = req_addr[3:0];
    // Word offset within the line (which 32-bit word, bits [3:2])
    wire [1:0]       req_woff = req_addr[3:2];

    wire hit0 = valid[req_set][0] && (tag[req_set][0] == req_tag);
    wire hit1 = valid[req_set][1] && (tag[req_set][1] == req_tag);
    wire hit  = hit0 | hit1;
    wire hit_way = hit1 ? 1'b1 : 1'b0;

    // LRU way to evict
    wire evict_way = lru[req_set];

    localparam ST_IDLE         = 3'd0;
    localparam ST_HIT_WRITE    = 3'd1;  // 1 cycle: apply write to the hit line
    localparam ST_EVALUATE      = 3'd2;  // waiting for L2 to be ready
    localparam ST_TRANSFER     = 3'd3;  // 4-cycle simultaneous evict↑ / fetch↓
    localparam ST_FILL         = 3'd4;  // apply fetched line + handle CPU op
    localparam ST_WRITE_L2_REQ_A = 3'd5;  // write-miss: send write-to-L2 request
    localparam ST_WRITE_L2_REQ_B= 3'd6;  // write-miss in L2 too → RAM (L2 handles)

    reg [2:0] state;
    reg [2:0] beat;//For L1 to L2 transfer purposes
    reg [LINE_BITS-1:0] fetch_buf; //fetches the value from L2
    reg [LINE_BITS-1:0] evict_buf; //If there is a dirty line, we must hold it


    integer i, j;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            busy          <= 1'b0;
            done          <= 1'b0;
            l1_req        <= 1'b0;
            l1_req_wr     <= 1'b0;
            l1_req_addr   <= 32'd0;
            l1_evict_valid<= 1'b0;
            l1_to_l2_data <= 16'd0;
            cpu_rd_data   <= 32'd0;
            beat          <= 2'd0;
            state         <= ST_IDLE;
            fetch_buf     <= 128'd0;
            evict_buf     <= 128'd0;
            req_addr      <= 32'd0;
            req_wr_en     <= 1'b0;
            req_wr_data   <= 32'd0;
            for (i = 0; i < SETS; i = i + 1) begin
                lru[i]      <= 1'b0;
                for (j = 0; j < WAYS; j = j + 1) begin
                    valid[i][j] <= 1'b0;
                    dirty[i][j] <= 1'b0;
                end
            end
        end else begin
            case (state)
                ST_IDLE : begin
                    if (cpu_en) begin
                        req_addr    <= cpu_addr;
                        req_wr_en   <= cpu_wr_en;
                        req_wr_data <= cpu_wr_data;
                        busy        <= 1'b1;
                        state <= ST_EVALUATE;
                    end else begin
                        busy <= 1'b0;
                    end
                    done           <= 1'b0;
                    l1_evict_valid <= 1'b0;
                end

                ST_EVALUATE : begin
                    if (hit) begin
                        if (req_wr_en) begin
                            state <= ST_HIT_WRITE;
                        end else begin
                            cpu_rd_data <= data[req_set][hit_way][req_woff*32 +: 32];
                            lru[req_set] <= ~hit_way;
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= ST_IDLE;
                        end
                    end else begin
                        if (req_wr_en) begin
                            l1_req      <= 1'b1;
                            l1_req_wr   <= 1'b1;
                            l1_req_addr <= {req_addr[31:4], 4'd0};// I added the 4'd0 to ensure that the offset of the line is not req
                            //Another way of writiing the above was {tag,index} basically
                            state <= ST_WRITE_L2_REQ_A;
                        end else begin
                            if (valid[req_set][evict_way] && dirty[req_set][evict_way]) begin
                                evict_buf <= data[req_set][evict_way];
                            end else begin
                                evict_buf <= 128'd0;
                            end
                            l1_req      <= 1'b1;
                            l1_req_wr   <= 1'b0;
                            l1_req_addr <= {req_addr[31:4], 4'd0};
                            l1_evict_valid <= valid[req_set][evict_way] && dirty[req_set][evict_way];
                            //Remember that if the data is not dirty, we dont care about it since a copy exists, hence it need not be buffered
                            if (!l2_busy) begin
                                beat  <= 2'd0;
                                state <= ST_TRANSFER;
                            end
                        end
                    end
                end

                ST_HIT_WRITE : begin
                    data[req_set][hit_way][req_woff*32 +: 32] <= req_wr_data;
                    dirty[req_set][hit_way] <= 1'b1;
                    lru[req_set]            <= ~hit_way;
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

                ST_TRANSFER : begin
                    l1_req <= 1'b0;
                    
                    case (beat)
                        3'd0 : begin
                            l1_to_l2_data <= evict_buf[15:0];
                            fetch_buf[15:0]    <= l2_to_l1_data;
                        end
                        3'd1 : begin
                            l1_to_l2_data <= evict_buf[31:16];
                            fetch_buf[31:16]   <= l2_to_l1_data;
                        end
                        3'd2 : begin
                            l1_to_l2_data <= evict_buf[47:32];
                            fetch_buf[47:32]   <= l2_to_l1_data;
                        end
                        3'd3 : begin
                            l1_to_l2_data <= evict_buf[63:48];
                            fetch_buf[63:48]   <= l2_to_l1_data;
                        end
                        3'd4 : begin
                            l1_to_l2_data <= evict_buf[79:64];
                            fetch_buf[79:64]   <= l2_to_l1_data;
                        end
                        3'd5 : begin
                            l1_to_l2_data <= evict_buf[95:80];
                            fetch_buf[95:80]   <= l2_to_l1_data;
                        end
                        3'd6 : begin
                            l1_to_l2_data <= evict_buf[111:96];
                            fetch_buf[111:96]  <= l2_to_l1_data;
                        end
                        3'd7 : begin
                            l1_to_l2_data <= evict_buf[127:112];
                            fetch_buf[127:112] <= l2_to_l1_data;
                        end
                        default: 
                    endcase

                    if (beat == 3'd7) begin
                        beat  <= 3'd0;
                        state <= ST_FILL;
                    end else begin
                        beat <= beat + 1'd1;
                    end
                end

                ST_FILL : begin

                    data [req_set][evict_way] <= fetch_buf;
                    tag  [req_set][evict_way] <= req_tag;
                    valid[req_set][evict_way] <= 1'b1;
                    dirty[req_set][evict_way] <= 1'b0;
                    lru  [req_set]            <= ~evict_way;
                    cpu_rd_data <= fetch_buf[req_woff*32 +: 32];

                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

                ST_WRITE_L2_REQ_A : begin
                    if (!l2_busy) begin
                        l1_req    <= 1'b0;
                        l1_to_l2_data <= req_wr_data[15:0];
                        state <= ST_WRITE_L2_REQ_B;
                    end
                end

                ST_WRITE_L2_REQ_B : begin
                    l1_to_l2_data <= req_wr_data[31:16];
                    if (l2_done) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
