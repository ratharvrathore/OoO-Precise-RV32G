module fpmult (
    input wire clk, reset,
    input wire [31:0] dataA, dataB,
    input wire pushNewMult,

    output wire [31:0] dataOut,
    output wire busy, done
);
    reg [31:0] dataASave, dataBSave;
    reg [2:0] state;
    reg [11:0] multA, multB;
    reg [23:0] compute1, compute2;
    reg [47:0] finalMult;
    reg [1:0] extraAdding;

    wire signA, signB;
    wire [7:0] expA, expB;
    wire [23:0] mantissaA, mantissaB, mantissaFinal;
    wire [23:0] multRes;
    wire [7:0] expFinal;

    assign signA = dataASave[31];
    assign signB = databSave[31];

    assign expA = dataASave[30:23];
    assign expB = dataBSave[30:23];

    assign mantissaA = {1'b1, dataASave[22:0]};
    assign mantissaB = {1'b1, dataBSave[22:0]};

    assign multRes = multA * multB;

    assign expFinal = expA + expB + {6'd0, extraAdding};

    assign mantissaFinal = (extraAdding == 2'd0) ? finalMult[45 -: 24] :
                           (extraAdding == 2'd1) ? finalMult[46 -: 24] :
                           finalMult[47 -: 24];

    localparam IDLE = 0;
    localparam COMPUTE_1 = 1;
    localparam COMPUTE_2 = 2;
    localparam COMPUTE_3 = 3;
    localparam SEND_ANS = 4;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            busy <= 0;
            done <= 0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 0;
                    if (pushNewMult) begin
                        dataASave <= dataA;
                        dataASave <= dataB;
                        busy <= 1;
                        state <= COMPUTE_1;
                        multA <= mantissaA[23:12];
                        multB <= mantissaB[23:12];
                    end
                end
                COMPUTE_1 : begin
                    compute1 <= multRes;
                    multA <= mantissaA[11:0];
                    multB <= mantissaB[11:0];
                    state <= COMPUTE_2;
                end
                COMPUTE_2 : begin
                    compute2 <= multRes;
                    multA <= mantissaA[11:0] + mantissaA[23:12];
                    multB <= mantissaB[11:0] + mantissaB[23:12];
                    state <= COMPUTE_3;
                end
                COMPUTE_3 : begin
                    finalMult <= (compute1 << 24) + compute2 + ((multRes - compute1 - compute2)<<12);
                    extraAdding <= (finalMult[47]) ? 2 :
                                   (finalMult[46]) ? 1:
                                   0;
                    state <= SEND_ANS;
                end
                SEND_ANS : begin
                    done <= 1;
                    busy <= 0;
                    dataOut <= {(signA ^ signB),(expFinal),(mantissaFinal[22:0])};
                end
                default: ;
            endcase
        end
    end
endmodule