module intToFp (
    input wire [31:0] dataIn,

    output wire [31:0] dataOut
);
    wire [31:0] twoComplement;
    wire [30:0] rawData;
    wire [53:0] extendedData;
    wire signIn;
    reg [4:0] firstOne;

    wire [7:0] expOut;
    wire [23:0] mantissaOut;

    assign signIn = dataIn[31];
    assign twoComplement = ~dataIn + 1;
    assign rawData = signIn ? twoComplement[30:0] : dataIn[30:0];

    integer i;

    always @(*) begin
        firstOne = 0;
        for (i = 0; i<31; i=i+1) begin
            if (rawData[i]) begin
                firstOne = i;
            end
        end
    end

    assign extendedData = {rawData, 23'd0};

    assign mantissaOut = extendedData[firstOne -: 24];

    assign expOut = {3'd0,firstOne} + 127;

    assign dataOut = {signIn, expOut, mantissaOut[22:0]};
endmodule