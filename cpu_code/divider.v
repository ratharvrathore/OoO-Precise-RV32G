module divider #(
    parameter WIDTH = 32
) (
    input wire clk, reset,
    input wire [31:0] dataA, dataB,
    input wire pushNewDiv,
    input wire signed_mode,

    output reg [31:0] quoOut, remOut,
    output reg busy, done,
    output reg exceptionRaised
);
    reg [63:0] remainder;
    reg [31:0] quotient;
    reg [31:0] divisorSave;
    reg [5:0] count;
    reg state;
    reg signA, signB;

    wire [63:0] remainderCompute;
    assign remainderCompute = (remainder << 1) - {32'd0, divisorSave};

    localparam IDLE    = 1'b0;
    localparam COMPUTE = 1'b1;

    wire div_by_zero    = (dataB == 32'd0);
    wire signed_overflow = signed_mode && (dataA == 32'h80000000) && (dataB == 32'hFFFFFFFF);

    function [31:0] absval;
        input [31:0] in;
        begin
            absval = in[31] ? (~in + 1'b1) : in;
        end
    endfunction

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            exceptionRaised <= 1'b0;
            quoOut <= 32'd0;
            remOut <= 32'd0;
            quotient <= 32'd0;
            remainder <= 64'd0;
            divisorSave <= 32'd0;
            count <= 6'd0;
            signA <= 1'b0;
            signB <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 1'b0;
                    exceptionRaised <= 1'b0;
                    if (pushNewDiv) begin
                        if (div_by_zero) begin
                            quoOut <= 32'hFFFFFFFF;
                            remOut <= dataA;
                            exceptionRaised <= 1'b1;
                            done <= 1'b1;
                            busy <= 1'b0;
                        end else if (signed_overflow) begin
                            quoOut <= 32'h80000000;
                            remOut <= 32'd0;
                            exceptionRaised <= 1'b1;
                            done <= 1'b1;
                            busy <= 1'b0;
                        end else begin
                            signA <= signed_mode & dataA[31];
                            signB <= signed_mode & dataB[31];
                            remainder <= {32'd0, (signed_mode ? absval(dataA) : dataA)};
                            divisorSave <= signed_mode ? absval(dataB) : dataB;
                            quotient <= 32'd0;
                            count <= 6'd32;
                            busy <= 1'b1;
                            state <= COMPUTE;
                        end
                    end
                end
                COMPUTE: begin
                    if (count == 6'd0) begin
                        quoOut <= (signA ^ signB) ? (~quotient + 1'b1) : quotient;
                        remOut <= signA ? (~remainder[31:0] + 1'b1) : remainder[31:0];
                        done <= 1'b1;
                        busy <= 1'b0;
                        state <= IDLE;
                    end else begin
                        count <= count - 1'b1;
                        if (remainderCompute[63] == 1'b0) begin
                            quotient[count-1] <= 1'b1;
                            remainder <= remainderCompute;
                        end else begin
                            quotient[count-1] <= 1'b0;
                            remainder <= remainder << 1;
                        end
                    end
                end
                default: ;
            endcase
        end
    end
endmodule