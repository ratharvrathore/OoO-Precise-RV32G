module ALU #(
    ALU_CONTROL_BITS = 5
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

    localparam ADD = 0;
    localparam SUB = 1;
    localparam XOR = 2;
    localparam OR = 3;
    localparam AND = 4;
    localparam SLL = 5;
    localparam SRL = 6;
    localparam SRA = 7;
    localparam SLT = 8;
    localparam SLTU = 9;
    localparam MUL = 10;
    localparam MULH = 11;
    localparam MULHSU = 12;
    localparam MULHU = 13;
    localparam DIV = 14;
    localparam DIVU = 15;
    localparam REM = 16;
    localparam REMU = 17;
    localparam FADD = 18;
    localparam FSUB = 19;
    localparam FMUL = 20;
    localparam FDIV = 21;
    localparam FSLT = 22;
    localparam FCTI = 23;
    localparam ICTF = 24;

    wire sOrU; //1=signed

    assign sOrU = 1; //INSTEAD OF WRITING 1 MAKE SOME LOGIC UP LATER

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