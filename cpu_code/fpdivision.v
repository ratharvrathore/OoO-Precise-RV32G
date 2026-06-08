module fpdivision (
    input wire clk, reset,
    input wire [31:0] dataA, dataB,
    input wire pushNewDiv,

    output reg [31:0] quoOut,
    output reg busy, done,
    output reg exceptionRaised    
);
    reg [23:0] dataASave, dataBSave, remainder, quotient;
    wire signA, signB, signOut;
    wire [7:0] expA, expB, expOut;
    wire [23:0] mantissaA, mantissaB;
    wire [22:0] finalWriting;
    wire extraAdding;

    wire divByZero = (dataB == 32'd0);

    reg [1:0] state;
    reg [4:0] count;

    localparam IDLE = 0;
    localparam COMPUTE = 1;
    localparam EXCEPTION = 2;

    assign {signA, expA, mantissaA[22:0]} = dataASave;
    assign {signB, expB, mantissaB[22:0]} = dataBSave;
    assign mantissaA[23] = 1;
    assign mantissaB[23] = 1;

    assign expOut = expA - expB - {7'b0,extraAdding} + 127;
    assign signOut = signA ^ signB;

    assign remainderCompute = remainder - dataBSave;

    assign extraAdding = ~quotient[23];

    assign finalWriting = quotient[23] ? quotient[23:1] : quotient[22:0];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            busy <= 0;
            done <= 0;
            exceptionRaised <= 0;
            count <= 23;
        end else begin
            case (state)
                IDLE: begin
                    done <= 0;
                    exceptionRaised <= 0;
                    if (pushNewDiv) begin
                        dataASave <= dataA;
                        remainder <= dataA;
                        dataBSave <= dataB;
                        quotient <= 0;
                        busy <= 1;
                        if (divByZero) begin
                            state <= EXCEPTION;
                        end else begin
                            state <= COMPUTE;
                        end
                    end
                end
                COMPUTE : begin
                    if (count == 0) begin
                        done <= 1;
                        busy <= 0;
                        state <= IDLE;
                        quoOut <= {signOut, expOut, finalWriting};
                    end else begin
                        count <= count - 1;
                        if (remainder > dataBSave) begin
                            remainder <= remainderCompute << 1;
                            quotient[count] <= 1;
                        end else begin
                            remainder <= remainder << 1;
                            quotient[count] <= 0;
                        end
                    end
                end
                EXCEPTION : begin
                    done <= 1;
                    exceptionRaised <= 1;
                    busy <= 0;
                    state <= IDLE;
                end
                default: ;
            endcase
        end
    end
endmodule