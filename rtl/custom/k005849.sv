//============================================================================
// 
//  SystemVerilog implementation of the Konami 005849 custom tilemap
//  generator
//  Adapted from Green Beret core Copyright (C) 2013, 2019 MiSTer-X
//  Copyright (C) 2021, 2022 Ace
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the 
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//
//============================================================================

//Note: This model of the 005849 cannot be used to replace an original 005849.

module k005849
(
	input         CK49,     //49.152MHz clock input
	output        NCK2,     //6.144MHz clock output
	output        X1S,      //3.072MHz clock output
	output        H2,       //1.576MHz clock output
	output        ER,       //E clock for MC6809E
	output        QR,       //Q clock for MC6809E
	output        EQ,       //AND of E and Q clocks for MC6809E
	input         RES,      //Reset input (actually an output on the original chip - active low)
	input         READ,     //Read enable (active low)
	input  [13:0] A,        //Address bus from CPU
	input   [7:0] DBi,      //Data bus input from CPU
	output  [7:0] DBo,      //Data output to CPU
	output  [3:0] VCF,      //Color address to tilemap LUT PROM
	output  [3:0] VCB,      //Tile index to tilemap LUT PROM
	input   [3:0] VCD,      //Data input from tilemap LUT PROM
	output  [3:0] OCF,      //Color address to sprite LUT PROM
	output  [3:0] OCB,      //Sprite index to sprite LUT PROM
	input   [3:0] OCD,      //Data input from sprite LUT PROM
	output  [4:0] COL,      //Color data output from color mixer
	input         XCS,      //Chip select (active low)
	input         BUSE,     //Data bus enable (active low)
	output        SYNC,     //Composite sync (active low)
	output        HSYC,     //HSync (active low) - Not exposed on the original chip
	output        VSYC,     //VSync (active low)
	output        HBLK,     //HBlank (active high) - Not exposed on the original chip
	output        VBLK,     //VBlank (active high) - Not exposed on the original chip
	output        FIRQ,     //Fast IRQ output
	output        IRQ,      //VBlank IRQ
	output        NMI,      //Non-maskable IRQ
	output        IOCS,     //I/O decoder enable (active low)
	output        CS80,     //Chip select output for Konami 501 custom chip (active low)
	
	//Split sprite/tile busses
	output [15:0] R,        //Address output to graphics ROMs (tiles)
	output [15:0] S,        //Address output to graphics ROMs (sprites)
	input   [7:0] RD,       //Tilemap ROM data
	input   [7:0] SD,       //Sprite ROM data
	
	//Extra input for flipping the sprite bank bit (active low)
	input         SPFL,
	
	//Extra inputs for screen centering (alters HSync and VSync timing to reposition the video output)
	input   [3:0] HCTR, VCTR,

	//MiSTer high score system I/O
	input  [11:0] hs_address,
	input   [7:0] hs_data_in,
	output  [7:0] hs_data_out,
	input         hs_write_enable,
	input         hs_access_write
);

//------------------------------------------------------- Signal outputs -------------------------------------------------------//

//Generate IOCS output (active low)
assign IOCS = ~(~XCS & (A[13:12] == 2'b11));

//Generate chip enable for Konami 501 (active low)
assign CS80 = XCS;

//Data output to CPU
assign DBo = BUSE                        ? 8'hFF:
             (cs_regs & ~READ)           ? regs:
             (zram0_cs & ~READ)          ? zram0_Dout:
             (zram1_cs & ~READ)          ? zram1_Dout:
             (tileram_attrib_cs & ~READ) ? tileram_attrib_Dout:
             (tileram_code_cs & ~READ)   ? tileram_code_Dout:
             (spriteram_cs & ~READ)      ? spriteram_Dout:
             8'hFF;

//------------------------------------------------------- Clock division -------------------------------------------------------//

//Divide the incoming 49.152MHz clock to 6.144MHz and 3.072MHz
reg [4:0] div = 4'd0;
always_ff @(posedge CK49) begin
	div <= div + 4'd1;
end
reg [3:0] n_div = 4'd0;
always_ff @(negedge CK49) begin
	n_div <= n_div + 4'd1;
end
wire cen_6m = !div[2:0];
wire n_cen_6m = !n_div[2:0];
wire cen_3m = !div[3:0];
assign NCK2 = div[2];
assign X1S = h_cnt[0];
assign H2 = h_cnt[1];

//The MC6809E requires two identical clocks with a 90-degree offset - assign these here
reg mc6809e_E = 0;
reg mc6809e_Q = 0;
always_ff @(posedge CK49) begin
	reg [1:0] clk_phase = 0;
	if(cen_6m) begin
		clk_phase <= clk_phase + 1'd1;
		case(clk_phase)
			2'b00: mc6809e_E <= 0;
			2'b01: mc6809e_Q <= 1;
			2'b10: mc6809e_E <= 1;
			2'b11: mc6809e_Q <= 0;
		endcase
	end
end
assign QR = mc6809e_Q;
assign ER = mc6809e_E;

//Output EQ combines ER and QR together via an AND gate - assign this here
assign EQ = ER & QR;

//-------------------------------------------------------- Video timings -------------------------------------------------------//

//The horizontal and vertical counters are 9 bits wide - delcare them here
reg [8:0] h_cnt = 9'd0;
reg [8:0] v_cnt = 9'd0;

//Increment horizontal counter on every falling edge of the pixel clock and increment vertical counter when horizontal counter
//rolls over
reg hblank = 0;
reg vblank = 0;
reg vblank_irq_en = 0;
reg frame_odd_even = 0;
reg hmask = 0;
always_ff @(posedge CK49) begin
	if(cen_6m) begin
		case(h_cnt)
			0: begin
				vblank_irq_en <= 0;
				h_cnt <= h_cnt + 9'd1;
			end
			1: begin
				hblank <= 0;
				h_cnt <= h_cnt + 9'd1;
			end
			9: begin
				hmask <= 0;
				h_cnt <= h_cnt + 9'd1;
			end
			//Blank the left-most and right-most 8 lines when the 005849's horizontal mask register bit
			//(register 3 bit 7) is active
			249: begin
				if(hmask_en)
					hmask <= 1;
				h_cnt <= h_cnt + 9'd1;
			end
			257: begin
				hblank <= 1;
				h_cnt <= h_cnt + 9'd1;
			end
			383: begin
				h_cnt <= 0;
				case(v_cnt)
					15: begin
						vblank <= 0;
						v_cnt <= v_cnt + 9'd1;
					end
					239: begin
						vblank <= 1;
						vblank_irq_en <= 1;
						frame_odd_even <= ~frame_odd_even;
						v_cnt <= v_cnt + 9'd1;
					end
					263: begin
						v_cnt <= 9'd0;
					end
					default: v_cnt <= v_cnt + 9'd1;
				endcase
			end
			default: h_cnt <= h_cnt + 9'd1;
		endcase
	end
end

//Output HBlank and VBlank (both active high)
assign HBLK = hblank;
assign VBLK = vblank;

//Generate horizontal sync and vertical sync (both active low)
assign HSYC = HCTR[3] ? ~(h_cnt >= 285 - ~HCTR[2:0] && h_cnt <= 316 - ~HCTR[2:0]) : ~(h_cnt >= 293 + HCTR[2:0] && h_cnt <= 324 + HCTR[2:0]);
assign VSYC = ~(v_cnt >= 254 - VCTR && v_cnt <= 261 - VCTR);
assign SYNC = HSYC ^ VSYC;

//------------------------------------------------------------- IRQs -----------------------------------------------------------//

//IRQ (triggers every VBlank)
reg vblank_irq = 1;
always_ff @(posedge CK49 or negedge RES) begin
	if(!RES)
		vblank_irq <= 1;
	else if(cen_6m) begin
		if(!irq_mask)
			vblank_irq <= 1;
		else if(vblank_irq_en)
			vblank_irq <= 0;
	end
end
assign IRQ = vblank_irq;

//NMI (triggers every 32 scanlines)
reg nmi = 1;
always_ff @(posedge CK49 or negedge RES) begin
	if(!RES)
		nmi <= 1;
	else if(cen_3m) begin
		if(!nmi_mask)
			nmi <= 1;
		else if(v_cnt % 9'd32 == 31)
			nmi <= 0;
	end
end
assign NMI = nmi;

//FIRQ (triggers every second VBlank)
reg firq = 1;
always_ff @(posedge CK49 or negedge RES) begin
	if(!RES)
		firq <= 1;
	else if(cen_3m) begin
		if(!firq_mask)
			firq <= 1;
		else if(!frame_odd_even && v_cnt == 9'd240)
			firq <= 0;
	end
end
assign FIRQ = firq;

//----------------------------------------------------- Internal registers -----------------------------------------------------//

//The 005849 has five 8-bit registers - handle these here
wire cs_regs = ~XCS & (A[13:12] == 2'b10) & (A[7:3] == 5'b01000);
reg [7:0] reg0, reg1, reg2, reg3, reg4;
//Write to the appropriate register
always_ff @(posedge CK49) begin
	if(cen_3m) begin
		if(cs_regs && READ) begin
			case(A[2:0])
				3'b000: reg0 <= DBi;
				3'b001: reg1 <= DBi;
				3'b010: reg2 <= DBi;
				3'b011: reg3 <= DBi;
				3'b100: reg4 <= DBi;
				default:;
			endcase
		end
	end
end

//Assign ZRAM scroll direction as bit 2 of register 2
wire zram_scroll_dir = reg2[2];

//Assign tilemap bank as bit 0 of register 3
wire tilemap_bank = reg3[0];

//Assign tile priority override as bit 6 of register 3 (this is used by Jailbreak to give full priority to sprites and override
//the layer priority set by bit 7 of the tilemap attribute)
wire tile_priority_override = reg3[6];

//Assign horizontal mask enable as bit 7 of register 3 (this bit, when enabled, masks the left-most and right-most 8 columns to
//reduce the active area from 256x224 to 240x224
wire hmask_en = reg3[7];

//Assign IRQ masks and flipscreen from the lower 4 bits of register 4
wire nmi_mask = reg4[0];
wire irq_mask = reg4[1];
wire firq_mask = reg4[2];
wire flipscreen = reg4[3];

wire [7:0] regs = (A == 14'h2040) ? reg0:
                  (A == 14'h2041) ? reg1:
                  (A == 14'h2042) ? reg2:
                  (A == 14'h2043) ? reg3:
                  8'hFF;

//-------------------------------------------------------- Internal ZRAM -------------------------------------------------------//

wire zram0_cs = ~XCS & (A[13:12] == 2'b10) & (A[7:0] >= 8'h00 && A[7:0] <= 8'h1F);
wire zram1_cs = ~XCS & (A[13:12] == 2'b10) & (A[7:0] >= 8'h20 && A[7:0] <= 8'h3F);

//Address ZRAM with bits [7:3] of the tilemap horizontal or vertical position depending on whether line scroll or column scroll
//is in use
wire [4:0] zram_A = zram_scroll_dir ? tilemap_hpos[7:3] : tilemap_vpos[7:3];
wire [7:0] zram0_D, zram1_D, zram0_Dout, zram1_Dout;
dpram_dc #(.widthad_a(5)) ZRAM0
(
	.clock_a(CK49),
	.address_a(A[4:0]),
	.data_a(DBi),
	.q_a(zram0_Dout),
	.wren_a(zram0_cs & READ),
	
	.clock_b(CK49),
	.address_b(zram_A),
	.q_b(zram0_D)
);
dpram_dc #(.widthad_a(5)) ZRAM1
(
	.clock_a(CK49),
	.address_a(A[4:0]),
	.data_a(DBi),
	.q_a(zram1_Dout),
	.wren_a(zram1_cs & READ),
	
	.clock_b(CK49),
	.address_b(zram_A),
	.q_b(zram1_D)
);

//------------------------------------------------------------ VRAM ------------------------------------------------------------//

//VRAM is external to the 005849 and combines multiple banks into a single 8KB RAM chip for tile attributes and data, and two sprite
//banks.  For simplicity, this RAM has been made internal to the 005849 implementation and split into its constituent components.
wire tileram_attrib_cs = ~XCS & (A[13:11] == 3'b000);
wire tileram_code_cs = ~XCS & (A[13:11] == 3'b001);
wire spriteram_cs = ~XCS & (A[13:12] == 2'b01);

wire [7:0] tileram_attrib_Dout, tileram_code_Dout, spriteram_Dout, tileram_attrib_D, tileram_code_D, spriteram_D;
//Tilemap
dpram_dc #(.widthad_a(11)) VRAM_TILEATTRIB
(
	.clock_a(CK49),
	.address_a(A[10:0]),
	.data_a(DBi),
	.q_a(tileram_attrib_Dout),
	.wren_a(tileram_attrib_cs & READ),
	
	.clock_b(CK49),
	.address_b(vram_A),
	.q_b(tileram_attrib_D)
);
dpram_dc #(.widthad_a(11)) VRAM_TILECODE
(
	.clock_a(CK49),
	.address_a(A[10:0]),
	.data_a(DBi),
	.q_a(tileram_code_Dout),
	.wren_a(tileram_code_cs & READ),
	
	.clock_b(CK49),
	.address_b(vram_A),
	.q_b(tileram_code_D)
);

`ifndef MISTER_HISCORE
//Sprites
dpram_dc #(.widthad_a(12)) VRAM_SPR
(
	.clock_a(CK49),
	.address_a(A[11:0]),
	.data_a(DBi),
	.q_a(spriteram_Dout),
	.wren_a(spriteram_cs & READ),
	
	.clock_b(CK49),
	.address_b({3'b000, sprite_bank, spritecache_A[7:0]}),
	.q_b(spriteram_D)
);
`else
// Hiscore mux (this is only to be used with Jailbreak as its high scores are stored in sprite RAM)
// - Mirrored sprite RAM used to protect against corruption while retrieving highscore data
wire [11:0] VRAM_SPR_AD = hs_access_write ? hs_address : A[11:0];
wire [7:0] VRAM_SPR_DIN = hs_access_write ? hs_data_in : DBi;
wire VRAM_SPR_WE = hs_access_write ? hs_write_enable : (spriteram_cs & READ);
//Sprites
dpram_dc #(.widthad_a(12)) VRAM_SPR
(
	.clock_a(CK49),
	.address_a(VRAM_SPR_AD),
	.data_a(VRAM_SPR_DIN),
	.q_a(spriteram_Dout),
	.wren_a(VRAM_SPR_WE),
	
	.clock_b(CK49),
	.address_b({3'b000, sprite_bank, spritecache_A[7:0]}),
	.q_b(spriteram_D)
);
//Sprite RAM shadow for highscore read access
dpram_dc #(.widthad_a(12)) VRAM_SPR_SHADOW
(
	.clock_a(CK49),
	.address_a(VRAM_SPR_AD),
	.data_a(VRAM_SPR_DIN),
	.wren_a(VRAM_SPR_WE),
	
	.clock_b(CK49),
	.address_b(hs_address),
	.q_b(hs_data_out)
);
`endif

//Sprite cache - this isn't present on the original 005849; it is used here to simulate framebuffer-like behavior where
//sprites are rendered with a 1-frame delay without using an actual framebuffer to save on limited FPGA BRAM resources
//This cache will copy all sprites from sprite RAM during an active frame for the sprite logic to read back on the next
//frame
reg [8:0] spritecache_A = 9'd0;
always_ff @(posedge CK49) begin
	if(cen_6m) begin
		if(spritecache_we)
			spritecache_A <= spritecache_A + 9'd1;
		else if(vblank)
			spritecache_A <= 9'd0;
		else
			spritecache_A <= spritecache_A;
	end
end	
wire [7:0] spriteram_Dcache;
wire spritecache_we = ~vblank & ~spritecache_A[8];
dpram_dc #(.widthad_a(9)) SPR_CACHE
(
	.clock_a(CK49),
	.address_a({frame_odd_even, spritecache_A[7:0]}),
	.data_a(spriteram_D),
	.wren_a(spritecache_we),
	
	.clock_b(~CK49),
	.address_b({~frame_odd_even, spriteram_A}),
	.q_b(spriteram_Dcache)
);

//-------------------------------------------------------- Tilemap layer -------------------------------------------------------//

//**The following code is the original tilemap renderer from MiSTerX's Green Beret core with some minor tweaks**//
//XOR horizontal and vertical counter bits with flipscreen bit
wire [8:0] hcnt_x = h_cnt ^ {9{flipscreen}};
wire [8:0] vcnt_x = v_cnt ^ {9{flipscreen}};

//Generate tilemap position - horizontal position is the sum of the horizontal counter, vertical position is the vertical counter
//
wire [8:0] tilemap_hpos = {h_cnt[8], hcnt_x[7:0]} + (~zram_scroll_dir ? {zram1_D[0], zram0_D} : 9'd0);
wire [8:0] tilemap_vpos = vcnt_x + (zram_scroll_dir ? {zram1_D[0], zram0_D} : 9'd0);

//Address output to tile section of VRAM
wire [10:0] vram_A = {tilemap_vpos[7:3], tilemap_hpos[8:3]};

//Tile index is a combination of the tilemap bank bit from the 005849's internal registers, attribute bits [7:6] and the actual
//tile code
wire [10:0] tile_index = {tilemap_bank, tileram_attrib_D[7:6], tileram_code_D};

//Tile color is held in the lower 4 bits of tileram attributes
wire [3:0] tile_color = tileram_attrib_D[3:0];

//Tile flip attributes are stored in bits 4 (horizontal) and 5 (vertical)
wire tile_hflip = tileram_attrib_D[4];
wire tile_vflip = tileram_attrib_D[5];

//Assign address outputs to tile ROM
assign R = {tile_index, (tilemap_vpos[2:0] ^ {3{tile_vflip}}), (tilemap_hpos[2:1] ^ {2{tile_hflip}})};

//Multiplex tilemap ROM data down from 8 bits to 4 using bit 0 of the horizontal position
wire [3:0] tile_pixel = (tilemap_hpos[0] ^ tile_hflip) ? RD[3:0] : RD[7:4];

//Retrieve tilemap select bit from the NOR of bit 7 of the tile attributes with the priority override bit
reg tilemap_en = 0;
always_ff @(posedge CK49) begin
	if(n_cen_6m) begin
		tilemap_en <= ~(tileram_attrib_D[7] | tile_priority_override);
	end
end

//Address output to tilemap LUT PROM
assign VCF = tile_color;
assign VCB = tile_pixel;

//Delay tilemap data by one horizontal line
reg [3:0] tilemap_D = 4'd0;
always_ff @(posedge CK49) begin
	if(cen_6m)
		tilemap_D <= VCD;
end

//-------------------------------------------------------- Sprite layer --------------------------------------------------------//

//The following code is the original sprite renderer from MiSTerX's Green Beret core with additional screen flipping support and
//some extra tweaks

//Generate sprite position - horizontal position is the horizontal counter, vertical position is the vertical counter (offset by
//18, 17 when flipped, to properly position the sprite layer)
wire [8:0] sprite_hpos = h_cnt;
wire [8:0] sprite_vpos = flipscreen ? v_cnt + 9'd17 : v_cnt + 9'd18;

//Sprite state machine
reg [5:0] sprite_index;
reg [1:0] sprite_offset;
reg [2:0] sprite_fsm_state;
reg [8:0] sprite_x, sprite_code;
reg [7:0] sprite_y;
reg [4:0] sprite_width;
reg [3:0] sprite_color;
reg sprite_hflip, sprite_vflip;
always_ff @(posedge CK49) begin
	if(sprite_hpos == 9'd0) begin
		sprite_width <= 5'd0;
		sprite_index <= 6'd0;
		sprite_offset <= 2'd3;
		sprite_fsm_state <= 3'd1;
	end
	else 
		case(sprite_fsm_state)
			0: /* empty */ ;
			1: begin
				//If the sprite limit has been reached, hold the state machine in an empty state, otherwise latch the
				//sprite Y attribute
				if(sprite_index > 8'd47) //Render up to 48 sprites at once (index 0 - 47)
					sprite_fsm_state <= 3'd0;
				else begin
					sprite_y <= spriteram_Dcache;
					sprite_offset <= 2'd2;
					sprite_fsm_state <= sprite_fsm_state + 3'd1;
				end
			end
			2: begin
				//Skip the current sprite if it's inactive, otherwise latch X position bits [7:0]
				if(sprite_active) begin
					sprite_x[7:0] <= spriteram_Dcache;
					sprite_offset <= 2'd1;
					sprite_fsm_state <= sprite_fsm_state + 3'd1;
				end
				else begin
					sprite_index <= sprite_index + 6'd1;
					sprite_offset <= 2'd3;
					sprite_fsm_state <= 3'd1;
				end
			end
			3: begin
				//Latch bit 8 of the sprite X position and sprite code, as well as the sprite color and H/V flip attributes
				sprite_x[8] <= spriteram_Dcache[7];
				sprite_code[8] <= spriteram_Dcache[6];
				sprite_vflip <= spriteram_Dcache[5] ^ flipscreen;
				sprite_hflip <= spriteram_Dcache[4] ^ flipscreen;
				sprite_color <= spriteram_Dcache[3:0];
				sprite_offset <= 2'd0;
				sprite_fsm_state <= sprite_fsm_state + 3'd1;
			end
			4: begin
				//Latch bits [7:0] of the sprite code and set up the sprite width to write the sprite to the line buffer
				sprite_code[7:0] <= spriteram_Dcache;
				sprite_offset <= 2'd3;
				sprite_index <= sprite_index + 6'd1;
				sprite_width <= 5'b10000;
				sprite_fsm_state <= sprite_fsm_state + 3'd1;
			end
			5: begin
				sprite_width <= sprite_width + 5'd1;
				sprite_fsm_state <= wre ? sprite_fsm_state : 3'd1;
			end
			default:;
		endcase
end

//Subtract vertical sprite position from sprite Y parameter to obtain sprite height
wire [8:0] sprite_height = {1'b0, sprite_y} - sprite_vpos;

//Set when a sprite is active
wire sprite_active = (sprite_y != 0) & (sprite_height[8:5] == 4'b1111) & (sprite_height[4] ^ ~flipscreen);

wire [3:0] lx = sprite_width[3:0] ^ {4{sprite_hflip}};
wire [3:0] ly = sprite_height[3:0] ^ {4{~sprite_vflip}};

//Assign address outputs to sprite ROMs
assign S = {sprite_code, ly[3], lx[3], ly[2:0], lx[2:1]};

//Multiplex sprite ROM data down from 8 bits to 4 using bit 0 of the horizontal pixel
wire [3:0] sprite_pixel = lx[0] ? SD[3:0] : SD[7:4];

//Latch the sprite bank from bit 3 of register 3 on the rising edge of VSync and XNOR with the added SPFL signal to flip this bit
//for Green Beret
//TODO: Find the actual internal register bit (if any) on the 005849 to properly handle this
reg sprite_bank = 0;
reg old_vsync;
always_ff @(posedge CK49) begin
	old_vsync <= VSYC;
	if(!RES)
		sprite_bank <= 0;
	else if(!old_vsync && VSYC)
		sprite_bank <= ~(reg3[3] ^ SPFL);
end

wire [7:0] spriteram_A = {sprite_index, sprite_offset};

//Address output to sprite LUT PROM
assign OCF = sprite_color;
assign OCB = sprite_pixel;

//----------------------------------------------------- Sprite line buffer -----------------------------------------------------//

//The sprite line buffer is external to the 005849 and consists of four 4416 DRAM chips.  For simplicity, both the logic for the
//sprite line buffer and the sprite line buffer itself has been made internal to the 005849 implementation.

//Enable writing to sprite line buffer when bit 4 of the sprite width is 1
wire wre = sprite_width[4];

//Set sprite line buffer bank as bit 0 of the sprite vertical position
wire sprite_lbuff_bank = sprite_vpos[0];

//Sum sprite X position with the lower 4 bits of the sprite width to address the sprite line buffer
wire [8:0] wpx = sprite_x + sprite_width[3:0];

//Generate sprite line buffer write addresses
reg [9:0] lbuff_A;
reg [3:0] lbuff_Din;
reg lbuff_we;
always_ff @(posedge CK49) begin
	lbuff_A <= {~sprite_lbuff_bank, wpx};
	lbuff_we <= wre;
end

//Latch sprite LUT PROM data on the falling edge of the main clock
always_ff @(negedge CK49) begin
	lbuff_Din <= OCD;
end

//Generate read address for sprite line buffer on the rising edge of the pixel clock
reg [9:0] radr0 = 10'd0;
reg [9:0] radr1 = 10'd1;
always_ff @(posedge CK49) begin
	if(cen_6m)
		radr0 <= {sprite_lbuff_bank, flipscreen ? sprite_hpos - 9'd241 : sprite_hpos};
end

//Sprite line buffer
wire [3:0] lbuff_Dout;
dpram_dc #(.widthad_a(10)) LBUFF
(
	.clock_a(CK49),
	.address_a(lbuff_A),
	.data_a({4'd0, lbuff_Din}),
	.wren_a(lbuff_we & (lbuff_Din != 0)),
	
	.clock_b(CK49),
	.address_b(radr0),
	.data_b(8'h0),
	.wren_b(radr0 == radr1),
	.q_b({4'bZZZZ, lbuff_Dout})
);

//Latch sprite data from the sprite line buffer
wire lbuff_read_en = (div[2:0] == 3'b100);
reg [3:0] sprite_D = 4'd0;
always_ff @(posedge CK49) begin
	if(lbuff_read_en) begin
		if(radr0 != radr1)
			sprite_D <= lbuff_Dout;
		radr1 <= radr0;
	end
end

//--------------------------------------------------------- Color mixer --------------------------------------------------------//

//Multiplex tile and sprite data, then output the final result
wire tile_sprite_sel = (tilemap_en | ~(|sprite_D));
wire [3:0] tile_sprite_D = tile_sprite_sel ? tilemap_D : sprite_D;

//Latch and output pixel data
reg [4:0] pixel_D;
always_ff @(posedge CK49) begin
	if(cen_6m)
		pixel_D <= {tile_sprite_sel, tile_sprite_D};
end
//If the horizontal mask is active, black out the left-most and right-most 8 columns to limit the display area to 240x224, otherwise
//output the full 256x224
assign COL = hmask ? 5'd0 : pixel_D;

endmodule
