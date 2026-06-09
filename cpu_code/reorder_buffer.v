module reorder_buffer #(
    parameter SCHEDULER_TAG_BITS = 3,
    parameter REORDER_TAG_BITS = 4
) (
    input  wire clk,
    input  wire reset,

    output wire full,
    output wire empty,

    input  wire [1:0] typeIn,
    input  wire [4:0] rdIn,
    input  wire [31:0] memAddrIn,
    input  wire [31:0] dataIn,
    input  wire [31:0] pcPlus4In,
    input  wire exceptionFlagIn,
    input  wire [SCHEDULER_TAG_BITS-1:0] nextSchTag,

    input  wire [REORDER_TAG_BITS-1:0] tagA,
    input  wire [REORDER_TAG_BITS-1:0] tagB,
    input  wire push_fetch,
    input  wire push_reorder,

    input  wire [SCHEDULER_TAG_BITS-1:0] broadcastSchTag,

    output reg  [31:0] dataOutReg,
    output reg  [4:0] rdOut,
    output reg  regWrEn,
    output wire [REORDER_TAG_BITS-1:0] broadcastNextTag,

    output wire [31:0] dataOutA,
    output wire [31:0] dataOutB,
    output wire [SCHEDULER_TAG_BITS-1:0] schTagA,
    output wire [SCHEDULER_TAG_BITS-1:0] schTagB,
    output wire validA,
    output wire validB
);
    localparam ENTRY_COUNT = (1 << REORDER_TAG_BITS);

    reg [ENTRY_COUNT-1:0] valid;
    reg [ENTRY_COUNT-1:0] active;

    reg [1:0] typeOfIns [0:ENTRY_COUNT-1];
    reg [4:0] rd [0:ENTRY_COUNT-1];
    reg [31:0] memAddr [0:ENTRY_COUNT-1];
    reg [31:0] data [0:ENTRY_COUNT-1];
    reg [31:0] pcPlus4 [0:ENTRY_COUNT-1];
    reg exceptionFlag [0:ENTRY_COUNT-1];
    reg [SCHEDULER_TAG_BITS-1:0] schTag [0:ENTRY_COUNT-1];

    reg [REORDER_TAG_BITS-1:0] oldPtr;
    reg [REORDER_TAG_BITS-1:0] youngPtr;

    integer i;
    reg found_broadcast;
    reg [REORDER_TAG_BITS-1:0] broadcastIdx;

    wire notEmpty = |active;

    assign full = (youngPtr == oldPtr) && notEmpty;
    assign empty = (youngPtr == oldPtr) && ~notEmpty;

    assign dataOutA = data[tagA];
    assign dataOutB = data[tagB];
    assign schTagA = schTag[tagA];
    assign schTagB = schTag[tagB];
    assign validA = valid[tagA];
    assign validB = valid[tagB];

    assign broadcastNextTag = youngPtr;

    always @(*) begin
        found_broadcast = 1'b0;
        broadcastIdx = {REORDER_TAG_BITS{1'b0}};
        for (i = 0; i < ENTRY_COUNT; i = i + 1) begin
            if (!found_broadcast && active[i] && (schTag[i] == broadcastSchTag)) begin
                found_broadcast = 1'b1;
                broadcastIdx = i[REORDER_TAG_BITS-1:0];
            end
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            oldPtr <= {REORDER_TAG_BITS{1'b0}};
            youngPtr <= {REORDER_TAG_BITS{1'b0}};
            valid <= {ENTRY_COUNT{1'b0}};
            active <= {ENTRY_COUNT{1'b0}};
            dataOutReg <= 32'd0;
            rdOut <= 5'd0;
            regWrEn <= 1'b0;
        end else begin
            regWrEn <= 1'b0;

            if (push_fetch && !full) begin
                typeOfIns[youngPtr] <= typeIn;
                rd[youngPtr] <= rdIn;
                memAddr[youngPtr] <= memAddrIn;
                pcPlus4[youngPtr] <= pcPlus4In;
                schTag[youngPtr] <= nextSchTag;
                valid[youngPtr] <= 1'b0;
                active[youngPtr] <= 1'b1;
                youngPtr <= youngPtr + {{(REORDER_TAG_BITS-1){1'b0}}, 1'b1};
            end

            if (push_reorder && found_broadcast) begin
                if (typeOfIns[broadcastIdx] == 2'b01) begin
                    data[broadcastIdx] <= pcPlus4[broadcastIdx];
                end else begin
                    data[broadcastIdx] <= dataIn;
                end
                exceptionFlag[broadcastIdx] <= exceptionFlagIn;
                valid[broadcastIdx] <= 1'b1;
            end

            if (valid[oldPtr]) begin
                dataOutReg <= data[oldPtr];
                rdOut <= rd[oldPtr];
                regWrEn <= typeOfIns[oldPtr][1] && (rd[oldPtr] != 5'd0);
                valid[oldPtr] <= 1'b0;
                active[oldPtr] <= 1'b0;
                oldPtr <= oldPtr + {{(REORDER_TAG_BITS-1){1'b0}}, 1'b1};
            end
        end
    end
endmodule
