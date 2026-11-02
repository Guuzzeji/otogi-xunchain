/* Scanned, never compiled: tools.recomp --exclude-manual ../seeds/manual.h.
 * "void sub_X(void) {" = replaced by src/*.zig; the lifter leaves the body out.
 * "extern void sub_X_gen(void);" = wrapped: the lifter emits the body as sub_X_gen
 * and src/*.zig defines sub_X around it. Keep in sync with the Zig exports. */

/* src/manual.zig: boot */
void sub_000E571D(void) {}  /* XAPI DVD media check */
void sub_000FA2A0(void) {}  /* D3D_BlockOnTime */
void sub_000C81A0(void) {}  /* game: XMV movie step */

/* src/manual.zig: XAPI input */
void sub_0016E924(void) {}  /* XInitDevices */
void sub_0016E929(void) {}  /* XGetDevices */
void sub_0016E94B(void) {}  /* XGetDeviceChanges */
void sub_0016EA1A(void) {}  /* XInputOpen */
void sub_0016EA70(void) {}  /* XInputClose */
void sub_0016EA7C(void) {}  /* XInputGetCapabilities */
void sub_0016EC54(void) {}  /* XInputGetState */
void sub_0016ECC7(void) {}  /* XInputSetState */

/* src/gl_hle.zig: D3D8 (XDK 5455, names from XbSymbolDatabase) */
extern void sub_000F4D00_gen(void);  /* D3DDevice_Swap */
extern void sub_000F4EB0_gen(void);  /* D3DDevice_Clear */
extern void sub_000F8330_gen(void);  /* D3DDevice_SetViewport */
extern void sub_000F78D0_gen(void);  /* D3DDevice_SetTransform */
extern void sub_000F8590_gen(void);  /* D3DDevice_SetTexture */
extern void sub_000F7130_gen(void);  /* D3DDevice_SetStreamSource */
extern void sub_000F8740_gen(void);  /* D3DDevice_SetIndices */
extern void sub_000F7530_gen(void);  /* D3DDevice_SetVertexShader */
extern void sub_000F95E0_gen(void);  /* D3DDevice_SetPixelShader */
extern void sub_000F6EC0_gen(void);  /* D3DDevice_CreateVertexShader */
extern void sub_000F7020_gen(void);  /* D3DDevice_SetVertexShaderConstant1 (fastcall) */
extern void sub_000F7080_gen(void);  /* D3DDevice_SetVertexShaderConstant4 (fastcall) */
extern void sub_000FA090_gen(void);  /* D3DDevice_BeginPush */
extern void sub_000FA0B0_gen(void);  /* D3DDevice_EndPush */
void sub_000F90F0(void) {}           /* D3DDevice_DrawVertices: replaced */
void sub_000F9190(void) {}           /* D3DDevice_DrawIndexedVertices: replaced */
extern void sub_000F7CF0_gen(void);  /* D3DDevice_SetRenderTarget */
extern void sub_000F7FC0_gen(void);  /* D3DDevice_CopyRects */
extern void sub_000F9570_gen(void);  /* D3DDevice_CreatePixelShader */
