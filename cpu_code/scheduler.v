module scheduler #(
    parameter SCHEDULER_TAG_BITS = 3,
    parameter ALU_CONTROL_BITS = 5
) (
    input wire clk, reset,

    output wire full, empty,

    input wire [31:0] dataAIn, dataBIn,
    input wire [SCHEDULER_TAG_BITS-1:0] tagAIn, tagBIn,
    input wire availableA, availableB,
    input wire memEnIn,
    input wire memWrEnIn,
    input wire jumpIn,
    input wire [ALU_CONTROL_BITS-1:0] aluControlIn,

    input wire push_fetch,
    input wire push_schdule,
    input wire push_reorder,

    input wire [31:0] broadcastData,
    input wire [SCHEDULER_TAG_BITS-1:0] broadcastTag,

    output reg [31:0] dataOutA, dataOutB,
    output reg [SCHEDULER_TAG_BITS-1:0] tagOut,
    output reg [ALU_CONTROL_BITS-1:0] aluControlOut,
    output reg memEnOut, memWrEnOut, jumpOut,

    output wire [SCHEDULER_TAG_BITS-1:0] nextSchTag
);
    reg [SCHEDULER_TAG_BITS-1:0] youngIdx, poppedIdx, preFirstValidEntry;
    wire [SCHEDULER_TAG_BITS-1:0] youngMapping, firstValidEntry, preNextSchTag;
    reg [(1<<SCHEDULER_TAG_BITS)-1:0] lookupTable [0:(1<<SCHEDULER_TAG_BITS)-1];
    wire [(1<<SCHEDULER_TAG_BITS)-1:0] updatedLookupTable [0:(1<<SCHEDULER_TAG_BITS)-1];

    reg [(1<<SCHEDULER_TAG_BITS)-1:0] active, validA, validB, memEn, memWrEn, jump;
    reg [31:0] dataA [0:(1<<SCHEDULER_TAG_BITS)-1];
    reg [31:0] dataB [0:(1<<SCHEDULER_TAG_BITS)-1];
    reg [SCHEDULER_TAG_BITS-1:0] tagA [0:(1<<SCHEDULER_TAG_BITS)-1];
    reg [SCHEDULER_TAG_BITS-1:0] tagB [0:(1<<SCHEDULER_TAG_BITS)-1];
    reg [ALU_CONTROL_BITS-1:0] aluControl [0:(1<<SCHEDULER_TAG_BITS)-1];

    reg stateDecode, stateReorder, stateSchedule;
    localparam IDLE = 0;
    localparam ADD_ENTRY = 1;
    localparam UPDATE_ENTRY = 1;
    localparam POP_ENTRY = 1;

    initial begin
        youngIdx = 0;
        poppedIdx = {SCHEDULER_TAG_BITS{1'b1}};
    end

    integer i;
    genvar j;

    generate
        for (j = 0; j<((1<<SCHEDULER_TAG_BITS)); j=j+1) begin
            assign updatedLookupTable[j] = (j=={SCHEDULER_TAG_BITS{1'b1}}) ? lookupTable[poppedIdx] : ((j >= poppedIdx) ? lookupTable[j+1] : lookupTable[j]);
        end
    endgenerate

    assign youngMapping = lookupTable[youngIdx];

    assign preNextSchTag = youngIdx;

    assign nextSchTag = lookupTable[preNextSchTag];

    assign firstValidEntry = lookupTable[preFirstValidEntry];

    assign full = &active;
    assign empty = ~(|active);

    always @(*) begin
        preFirstValidEntry = 0;
        for (i = (1<<SCHEDULER_TAG_BITS) - 1; i>=0; i = i-1) begin
            if(active[i] & validA[i] & validB[i]) begin
                preFirstValidEntry = i;
            end
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i<((1<<SCHEDULER_TAG_BITS)); i=i+1) begin
                lookupTable[i] <= i;
            end
            stateDecode <= 0;
            stateReorder <= 0;
            stateSchedule <= 0;
            active <= 0;
            validA <= 0;
            validB <= 0;
        end
    end
    always @(posedge clk ) begin
        case (stateDecode)
            IDLE : begin
                if (push_fetch) begin
                    stateDecode <= ADD_ENTRY;
                end
            end
            ADD_ENTRY : begin
                youngIdx <= youngIdx + 1;
                active[nextSchTag] <= 1;
                validA[nextSchTag] <= availableA;
                validB[nextSchTag] <= availableB;
                tagA[nextSchTag] <= tagAIn;
                tagB[nextSchTag] <= tagBIn;
                dataA[nextSchTag] <= dataAIn;
                dataB[nextSchTag] <= dataBIn;
                memEn[nextSchTag] <= memEnIn;
                memWrEn[nextSchTag] <= memWrEn;
                jump[nextSchTag] <= jumpIn;
                aluControl[nextSchTag] <= aluControlIn;
                stateDecode <= IDLE;
            end
            default: ;
        endcase
    end
    always @(posedge clk ) begin
        case (stateSchedule)
            IDLE : begin
                if (push_schdule) begin
                    stateSchedule <= POP_ENTRY;
                end
            end
            POP_ENTRY : begin
                youngIdx <= youngIdx - 1;
                dataOutA <= dataA[firstValidEntry];
                dataOutB <= dataB[firstValidEntry];
                tagOut <= firstValidEntry;
                aluControlOut <= aluControl[firstValidEntry];
                memEnOut <= memEn[firstValidEntry];
                memWrEnOut <= memWrEn[firstValidEntry];
                jumpOut <= jump[firstValidEntry];
                active[firstValidEntry] <= 0;
                poppedIdx <= preFirstValidEntry;
                stateSchedule <= IDLE;
                for (i = 0; i<(1<<SCHEDULER_TAG_BITS); i=i+1) begin
                   lookupTable[i] <= updatedLookupTable[i]; 
                end
            end
            default: ;
        endcase
    end

    //CAM but multiple assignments could be waiting so we put a comparator in front of each
    wire [(1<<SCHEDULER_TAG_BITS)-1:0] equalToBroadcastTagA, equalToBroadcastTagB;
    generate
        for (j = 0; j<(1<<SCHEDULER_TAG_BITS); j = j+1) begin
            assign equalToBroadcastTagA[j] = (tagA[j] == broadcastTag);
            assign equalToBroadcastTagB[j] = (tagB[j] == broadcastTag);
        end
    endgenerate
    always @(posedge clk ) begin
        case (stateReorder)
            IDLE : begin
                if(push_reorder) begin
                    stateReorder <= UPDATE_ENTRY;
                end
            end
            UPDATE_ENTRY : begin
                for (i = 0; i<(1<<SCHEDULER_TAG_BITS); i = i+1) begin
                    if(equalToBroadcastTagA[i]) begin
                        dataA[i] <= broadcastData;
                        validA[i] <= 1;
                    end
                    if (equalToBroadcastTagB[i]) begin
                        dataB[i] <= broadcastData;
                        validB[i] <= 1;
                    end
                end
                stateReorder <= IDLE;
            end
            default: ;
        endcase
    end
endmodule