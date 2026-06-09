module scheduler #(
    parameter SCHEDULER_TAG_BITS = 3,
    parameter ALU_CONTROL_BITS = 6
) (
    input  wire clk,
    input  wire reset,

    output wire full,
    output wire empty,

    input  wire [31:0] dataAIn,
    input  wire [31:0] dataBIn,
    input  wire [SCHEDULER_TAG_BITS-1:0] tagAIn,
    input  wire [SCHEDULER_TAG_BITS-1:0] tagBIn,
    input  wire availableA,
    input  wire availableB,
    input  wire memEnIn,
    input  wire memWrEnIn,
    input  wire jumpIn,
    input  wire [ALU_CONTROL_BITS-1:0] aluControlIn,

    input  wire push_fetch,
    input  wire push_schdule,
    input  wire push_reorder,

    input  wire [31:0] broadcastData,
    input  wire [SCHEDULER_TAG_BITS-1:0] broadcastTag,

    output reg  [31:0] dataOutA,
    output reg  [31:0] dataOutB,
    output reg  [SCHEDULER_TAG_BITS-1:0] tagOut,
    output reg  [ALU_CONTROL_BITS-1:0] aluControlOut,
    output reg  memEnOut,
    output reg  memWrEnOut,
    output reg  jumpOut,

    output wire [SCHEDULER_TAG_BITS-1:0] nextSchTag
);
    localparam ENTRY_COUNT = (1 << SCHEDULER_TAG_BITS);

    reg [ENTRY_COUNT-1:0] active;
    reg [ENTRY_COUNT-1:0] validA;
    reg [ENTRY_COUNT-1:0] validB;
    reg [ENTRY_COUNT-1:0] memEn;
    reg [ENTRY_COUNT-1:0] memWrEn;
    reg [ENTRY_COUNT-1:0] jump;

    reg [31:0] dataA [0:ENTRY_COUNT-1];
    reg [31:0] dataB [0:ENTRY_COUNT-1];
    reg [SCHEDULER_TAG_BITS-1:0] tagA [0:ENTRY_COUNT-1];
    reg [SCHEDULER_TAG_BITS-1:0] tagB [0:ENTRY_COUNT-1];
    reg [ALU_CONTROL_BITS-1:0] aluControl [0:ENTRY_COUNT-1];

    reg [SCHEDULER_TAG_BITS-1:0] allocPtr;

    integer i;
    reg found_alloc;
    reg [SCHEDULER_TAG_BITS-1:0] alloc_idx;
    reg found_issue;
    reg [SCHEDULER_TAG_BITS-1:0] issue_idx;

    assign full = &active;
    assign empty = ~(|active);
    assign nextSchTag = alloc_idx;

    always @(*) begin
        found_alloc = 1'b0;
        alloc_idx = allocPtr;
        for (i = 0; i < ENTRY_COUNT; i = i + 1) begin
            if (!found_alloc && !active[(allocPtr + i) % ENTRY_COUNT]) begin
                found_alloc = 1'b1;
                alloc_idx = (allocPtr + i) % ENTRY_COUNT;
            end
        end

        found_issue = 1'b0;
        issue_idx = {SCHEDULER_TAG_BITS{1'b0}};
        for (i = 0; i < ENTRY_COUNT; i = i + 1) begin
            if (!found_issue && active[i] && validA[i] && validB[i]) begin
                found_issue = 1'b1;
                issue_idx = i[SCHEDULER_TAG_BITS-1:0];
            end
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            active <= {ENTRY_COUNT{1'b0}};
            validA <= {ENTRY_COUNT{1'b0}};
            validB <= {ENTRY_COUNT{1'b0}};
            memEn <= {ENTRY_COUNT{1'b0}};
            memWrEn <= {ENTRY_COUNT{1'b0}};
            jump <= {ENTRY_COUNT{1'b0}};
            allocPtr <= {SCHEDULER_TAG_BITS{1'b0}};
            dataOutA <= 32'd0;
            dataOutB <= 32'd0;
            tagOut <= {SCHEDULER_TAG_BITS{1'b0}};
            aluControlOut <= {ALU_CONTROL_BITS{1'b0}};
            memEnOut <= 1'b0;
            memWrEnOut <= 1'b0;
            jumpOut <= 1'b0;
        end else begin
            if (push_reorder) begin
                for (i = 0; i < ENTRY_COUNT; i = i + 1) begin
                    if (active[i] && !validA[i] && (tagA[i] == broadcastTag)) begin
                        validA[i] <= 1'b1;
                        dataA[i] <= broadcastData;
                    end
                    if (active[i] && !validB[i] && (tagB[i] == broadcastTag)) begin
                        validB[i] <= 1'b1;
                        dataB[i] <= broadcastData;
                    end
                end
            end

            if (push_fetch && !full && found_alloc) begin
                active[alloc_idx] <= 1'b1;
                validA[alloc_idx] <= availableA;
                validB[alloc_idx] <= availableB;
                dataA[alloc_idx] <= dataAIn;
                dataB[alloc_idx] <= dataBIn;
                tagA[alloc_idx] <= tagAIn;
                tagB[alloc_idx] <= tagBIn;
                memEn[alloc_idx] <= memEnIn;
                memWrEn[alloc_idx] <= memWrEnIn;
                jump[alloc_idx] <= jumpIn;
                aluControl[alloc_idx] <= aluControlIn;
                allocPtr <= alloc_idx + {{(SCHEDULER_TAG_BITS-1){1'b0}}, 1'b1};
            end

            if (push_schdule && found_issue) begin
                dataOutA <= dataA[issue_idx];
                dataOutB <= dataB[issue_idx];
                tagOut <= issue_idx;
                aluControlOut <= aluControl[issue_idx];
                memEnOut <= memEn[issue_idx];
                memWrEnOut <= memWrEn[issue_idx];
                jumpOut <= jump[issue_idx];
                active[issue_idx] <= 1'b0;
                validA[issue_idx] <= 1'b0;
                validB[issue_idx] <= 1'b0;
            end
        end
    end
endmodule
