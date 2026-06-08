module ALU #(
    ALU_CONTROL_BITS = 6
) (
    input wire clk, reset,
    input wire [31:0] dataA, dataB,
    input wire [ALU_CONTROL_BITS-1:0] ALUControl,
    
    output wire busy, done,
    output wire [31:0] dataOut,
    output wire exceptionRaised //mihgt be output reg also
);
    //float uses a different set of ISA
    //fused mult add was not implemented
    //MULT fused add and some other funcitons were not implemented here
    //The local param values can be mixed up for convinience or easier control unit coding but the essence is the same

    localparam ADD = 6'b0_0_1_000;
    localparam SUB = 6'b0_0_1_001;
    localparam XOR = 6'b0_0_0_000;
    localparam OR = 6'b0_0_0_001;
    localparam AND = 6'b0_0_0_010;
    localparam SLL = 6'b0_0_0_100;
    localparam SRL = 6'b0_0_0_101;
    localparam SRA = 6'b0_1_0_000;
    localparam SLT = 6'b0_0_1_111;
    localparam SLTU = 6'b1_0_1_111;
    localparam MUL = 6'b0_0_1_010;
    localparam MULU = 6'b1_0_1_010;
    localparam MULH = 6'b0_0_1_011;
    localparam MULHU = 6'b1_0_1_011;
    localparam DIV = 6'b0_0_1_100;
    localparam DIVU = 6'b1_0_1_100;
    localparam REM = 6'b0_0_1_101;
    localparam REMU = 6'b1_0_1_101;
    localparam FADD = 6'b0_1_1_000;
    localparam FSUB = 6'b0_1_1_001;
    localparam FMUL = 6'b0_1_1_010;
    localparam FDIV = 6'b0_1_1_100;
    localparam FSLT = 6'b0_1_1_111;
    localparam FCTI = 6'b0_1_0_001;
    localparam ICTF = 6'b0_1_0_010;

    wire sOrU;

    assign sOrU = ALUControl[5]; //INSTEAD OF WRITING 1 MAKE SOME LOGIC UP LATER

    wire [31:0] multInA, multInB, divInA, divInB, quoOut, remOut, addOut, subOut;
    wire [63:0] multOut;
    wire multBusy, multDone, multPushNewData, divBusy, divDone, divPushNewData, divException;

    .multiplier multiplier(
        .clk(clk),
        .reset(reset),
        .dataA(multInA),
        .dataB(multInB),
        .pushNewMult(multPushNewData),
        .signed_mode(sOrU),
        .dataOut(multOut),
        .busy(multBusy),
        .done(multDone),
    );

    .divider divider(
        .clk(clk),
        .reset(reset),
        .dataA(divInA),
        .dataB(divInB),
        .pushNewDiv(divPushNewData),
        .signed_mode(sOrU),
        .quoOut(quoOut),
        .remOut(remOut),
        .busy(divBusy),
        .done(divDone),
        .exceptionRaised(divException)
    );

    assign addOut = dataA + dataB;
    assign subOut = dataA - dataB;

    wire is_sub, fpAddException;
    wire [31:0] fpAddDataOut;

    .fp_addsub fp_addsub(
        .dataA(dataA),
        .dataB(dataB),
        .is_sub(is_sub),
        .dataOut(fpAddDataOut),
        .exceptionRaised(fpAddException)
    );

    wire fpSltRes; //set less than, as in is A<B?

    assign fpSltRes = (dataA[31] > dataB[31]) ? 1 : 
                      ((dataA[31] < dataB[31]) ? 0 : 
                      ((dataA[30:0] > dataB[30:0]) ? dataA[31] : ~dataA[31])) ; 

    wire [31:0] fpMultOut;
    wire fpMultBusy, fpMultDone, fpPushNewMult;

    .fpmult fpmult(
        .clk(clk),
        .reset(reset),
        .dataA(dataA),
        .dataB(dataB),
        .pushNewMult(fpPushNewMult),
        .dataOut(fpMultOut),
        .busy(fpMultBusy),
        .done(fpMultDone)
    );

    wire [31:0] fpDivOut;
    wire fpDivBusy, fpDivDone, fpPushNewDiv, fpDivException;

    .fpdivision fpdivision(
        .clk(clk),
        .reset(reset),
        .dataA(dataA),
        .dataB(dataB),
        .pushNewDiv(fpPushNewDiv),
        .quoOut(fpDivOut),
        .busy(fpDivBusy),
        .done(fpDivDone),
        .exceptionRaised(fpDivException)
    );

    wire [31:0] fpToInt;
    wire fpToIntException;

    .fpToInt fpToInt(
        .dataIn(dataA),
        .dataOut(fpToInt),
        .exceptionRaised(fpToIntException)
    );

    wire [31:0] intToFp;
    wire intToFpException;

    .intToFp intToFp(
        .dataIn(dataA),
        .dataOut(intToFp)
    );
endmodule