module reorder_buffer #(
    parameter SCHEDULER_TAG_BITS = 3,
    parameter REORDER_TAG_BITS = 4
) (
    input wire clk, reset,

    output wire full, empty,

    input wire [1:0] typeIn,
    input wire [4:0] rdIn,
    input wire [31:0] memAddrIn,
    input wire [31:0] dataIn, //from reorder broadcast
    input wire [31:0] pcPlus4In,
    input wire exceptionFlagIn,
    input wire [SCHEDULER_TAG_BITS - 1 : 0] nextSchTag,

    input wire [REORDER_TAG_BITS - 1 : 0] tagA, tagB,
    input wire push_fetch, push_reorder,

    input wire [SCHEDULER_TAG_BITS - 1 : 0] broadcastSchTag,

    output reg [31:0] dataOutReg,
    output reg [4:0] rdOut,
    output reg regWrEn,
    output wire [REORDER_TAG_BITS - 1 : 0] broadcastNextTag,

    output wire [31:0] dataOutA, dataOutB,
    output wire [SCHEDULER_TAG_BITS - 1:0] schTagA, schTagB,
    output wire validA, validB
);
    reg [2**REORDER_TAG_BITS - 1:0] valid = 0;
    reg [2**REORDER_TAG_BITS - 1:0] active = 0;
    reg [1:0] typeOfIns [0: 2**REORDER_TAG_BITS - 1]; //10:Exe, 11:load, 00:store, 01:jump (condition to change)
    reg [4:0] rd [0: 2**REORDER_TAG_BITS - 1];
    reg [31:0] memAddr [0: 2**REORDER_TAG_BITS - 1];
    reg [31:0] data [0: 2**REORDER_TAG_BITS - 1];
    reg [31:0] pcPlus4 [0: 2**REORDER_TAG_BITS - 1];
    reg exceptionFlag [0: 2**REORDER_TAG_BITS - 1];
    reg [SCHEDULER_TAG_BITS - 1:0] schTag [0: 2**REORDER_TAG_BITS - 1];

    reg [SCHEDULER_TAG_BITS - 1:0] old, young;
    reg [REORDER_TAG_BITS - 1:0] searchedTag;
    reg searchedFound;
    //wire [2**REORDER_TAG_BITS-1:0]notEmpty;
    wire notEmpty;
    localparam IDLE = 0;
    localparam PUSH_DATA = 1;
    localparam TAKE_DATA = 1;
    localparam POP_DATA = 1;

    reg stateDecode, stateReorder, stateWB;

    //For debugging only
    wire validDebug = valid[0];
    wire activeDebug = active[0];
    wire [1:0] typeOfInsDebug = typeOfIns[0]; //10:Exe, 11:load, 00:store, 01:jump (condition to change)
    wire [4:0] rdDebug = rd[0];
    wire [31:0] memAddrDebug = memAddr[0];
    wire [31:0] dataDebug = data[0];
    wire [31:0] pcPlus4Debug = pcPlus4[0];
    wire exceptionFlagDebug = exceptionFlag[0];
    wire [SCHEDULER_TAG_BITS - 1:0] schTagDebug = schTag[0];
    //Debugging code ends here

    // assign notEmpty[0] = valid[0];
    // genvar j;
    // generate
    //     for (j = 1; j < 2 ** REORDER_TAG_BITS; j = j+1) begin
    //         assign notEmpty[j] = notEmpty[j-1] | valid[j];
    //     end
    // endgenerate
    assign notEmpty = |active;
    assign full = (young == old) && notEmpty;
    assign empty = (young == old) && ~notEmpty;

    assign dataOutA = data[tagA];
    assign dataOutB = data[tagB];
    assign schTagA = schTag[tagA];
    assign schTagB = schTag[tagB];
    assign validA = valid[tagA];
    assign vlaidB = valid[tagB];

    assign broadcastNextTag = young + 1;

    always @(posedge clk or posedge reset) begin
        if(reset) begin
            stateDecode <= IDLE;
            stateReorder <= IDLE;
            stateWB <= IDLE;
            old <= 0;
            young <= 0;
        end
    end
    always @(posedge clk ) begin
        case (stateDecode)
            IDLE : begin
                if (push_fetch) begin
                    stateDecode <= PUSH_DATA;
                end
            end
            PUSH_DATA : begin
                young <= young + 1;
                valid[young] <= 0;
                active[young] <= 1;
                typeOfIns[young] <= typeIn;
                rd[young] <= rdIn;
                memAddr[young] <= memAddrIn;
                pcPlus4[young] <= pcPlus4In;
                schTag[young] <= nextSchTag;
                stateDecode <= IDLE;
            end
            default: ;
        endcase
    end

    //content addresable search
    integer i;
    always @(*) begin
        searchedTag = 0;
        searchedFound = 0;
        for (i = 0; i < 2**REORDER_TAG_BITS; i++) begin
            if(active[i] && (schTag[i]==broadcastSchTag)) begin
                searchedTag = i;
                searchedFound = 1;
            end
        end
    end
    always @(posedge clk ) begin
        case (stateReorder)
            IDLE : begin
                if (push_reorder) begin
                    stateReorder <= TAKE_DATA;
                end
            end
            TAKE_DATA : begin
                if(searchedFound) begin
                    data[searchedTag] <= dataIn;
                    exceptionFlag[searchedTag] <= exceptionFlagIn;
                    valid[searchedTag] <= 1;
                end
                stateReorder <= IDLE;
            end
            default: ;
        endcase
    end

    always @(posedge clk ) begin
        case (stateWB)
            IDLE : begin
                regWrEn <= 0;
                if (valid[old] == 1) begin
                    stateWB <= POP_DATA;
                end
            end
            POP_DATA : begin
                dataOutReg <= data[old];
                rdOut <= rd[old];
                regWrEn <= typeOfIns[old][1];
                old <= old + 1;
                valid[old] <= 0;
                active[old] <= 0;
                stateWB <= IDLE;
            end
            default: ;
        endcase
    end
endmodule