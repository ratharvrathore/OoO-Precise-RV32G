module fpToInt (
    input wire [31:0] dataIn,
    
    output wire [31:0] dataOut,
    output wire exceptionRaised
);
    wire signIn;
    wire isAnsZero;
    wire [7:0] expIn, expMinus127;
    wire [23:0] mantissaIn;
    wire [4:0] shiftAmt;
    wire [53:0] intermediate;
    wire [31:0] rawData;

    assign signIn = dataIn[31];
    assign expIn = dataIn[30:23];
    assign mantissaIn = {1'b1, dataIn[22:0]};

    assign exceptionRaised = (x>158);
    assign isAnsZero = (x<127);

    assign expMinus127 = expIn - 127;
    assign shiftAmt = expMinus127[4:0];

    assign intermediate = mantissaIn << shiftAmt;

    assign rawData = {1'b0, intermediate[53 -:31]};

    assign dataOut = isAnsZero ? (0) : (signIn ? (~rawData + 1) : rawData);
endmodule