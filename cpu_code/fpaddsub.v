module fp_addsub (
    input  wire [31:0] dataA, dataB,
    input  wire        is_sub,

    output wire [31:0] dataOut,
    output wire        exceptionRaised
);
    wire fA_sign, fB_sign_raw, fB_sign;
    wire [7:0]  fA_exp,  fB_exp;
    wire [22:0] fA_mant, fB_mant;

    assign fA_sign = dataA[31];
    assign fA_exp = dataA[30:23];
    assign fA_mant = dataA[22:0]; 
    assign fB_sign_raw = dataB[31];
    assign fB_exp = dataB[30:23];
    assign fB_mant = dataB[22:0];

    assign fB_sign = is_sub ? ~fB_sign_raw : fB_sign_raw;

    // Special-case detection
    wire fA_nan  = (fA_exp == 8'hFF) && (fA_mant != 0);
    wire fB_nan  = (fB_exp == 8'hFF) && (fB_mant != 0);
    wire fA_inf  = (fA_exp == 8'hFF) && (fA_mant == 0);
    wire fB_inf  = (fB_exp == 8'hFF) && (fB_mant == 0);
    wire fA_zero = (fA_exp == 8'h00) && (fA_mant == 0);
    wire fB_zero = (fB_exp == 8'h00) && (fB_mant == 0);

    // Restore hidden bit (0 for denormals, 1 for normals)
    wire [23:0] fA_sig = {(fA_exp != 8'h00), fA_mant};
    wire [23:0] fB_sig = {(fB_exp != 8'h00), fB_mant};

    wire fA_larger_exp = (fA_exp >= fB_exp);
    wire [7:0] exp_big = fA_larger_exp ? fA_exp : fB_exp;
    wire [7:0] exp_small = fA_larger_exp ? fB_exp : fA_exp;
    wire [7:0] exp_diff = exp_big - exp_smal ; 
    wire [23:0] sig_big = fA_larger_exp ? fA_sig : fB_sig;
    wire sign_big = fA_larger_exp ? fA_sign : fB_sign;
    wire [23:0] sig_small = fA_larger_exp ? fB_sig : fA_sig;
    wire sign_small = fA_larger_exp ? fB_sign : fA_sign;

    // Right-shift smaller significand, keep 2 guard bits
    wire [5:0]  shift_amt = (exp_diff > 25) ? 6'd25 : exp_diff[5:0];
    wire [25:0] sig_big_ext = {sig_big, 2'b00};
    wire [25:0] sig_small_ext = {sig_small, 2'b00} >> shift_amt;

    // Step 2: Add or subtract significands
    wire same_sign = (sign_big == sign_small);
    wire [26:0] sig_sum = same_sign ? ({1'b0, sig_big_ext} + {1'b0, sig_small_ext}) :
                                      ({1'b0, sig_big_ext} - {1'b0, sig_small_ext});

    wire res_sign = sign_big;

    // Step 3: Normalize
    wire [24:0] norm_field = sig_sum[26:2];
    wire carry_out  = sig_sum[26];

    wire [4:0] lz;
    assign lz = norm_field[24] ? 5'd0  :
                norm_field[23] ? 5'd1  :
                norm_field[22] ? 5'd2  :
                norm_field[21] ? 5'd3  :
                norm_field[20] ? 5'd4  :
                norm_field[19] ? 5'd5  :
                norm_field[18] ? 5'd6  :
                norm_field[17] ? 5'd7  :
                norm_field[16] ? 5'd8  :
                norm_field[15] ? 5'd9  :
                norm_field[14] ? 5'd10 :
                norm_field[13] ? 5'd11 :
                norm_field[12] ? 5'd12 :
                norm_field[11] ? 5'd13 :
                norm_field[10] ? 5'd14 :
                norm_field[9]  ? 5'd15 :
                norm_field[8]  ? 5'd16 :
                norm_field[7]  ? 5'd17 :
                norm_field[6]  ? 5'd18 :
                norm_field[5]  ? 5'd19 :
                norm_field[4]  ? 5'd20 :
                norm_field[3]  ? 5'd21 :
                norm_field[2]  ? 5'd22 :
                norm_field[1]  ? 5'd23 :
                                 5'd24;

    wire [24:0] shifted_sig = carry_out ? norm_field >> 1 : norm_field << lz;
    wire [7:0]  exp_norm = carry_out ? (exp_big + 8'd1) : (exp_big - {3'b000, lz});
    wire [22:0] mant_norm = shifted_sig[23:1];

    // Step 4: Special-case output
    localparam [31:0] CANONICAL_NAN = 32'h7FC00000;

    wire inf_minus_inf = fA_inf && fB_inf && (fA_sign != fB_sign);

    assign exceptionRaised = fA_nan || fB_nan || inf_minus_inf;

    assign dataOut = (fA_nan || fB_nan || inf_minus_inf) ? CANONICAL_NAN :
                    fA_inf ? {fA_sign, 8'hFF, 23'd0} :
                    fB_inf ? {fB_sign, 8'hFF, 23'd0} :
                    (fA_zero && fB_zero) ? 32'h00000000 :
                    (norm_field == 25'd0) ? 32'h00000000 :
                    {res_sign, exp_norm, mant_norm};

endmodule