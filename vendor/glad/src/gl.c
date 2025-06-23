/**
 * SPDX-License-Identifier: (WTFPL OR CC0-1.0) AND Apache-2.0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <glad/gl.h>

#ifndef GLAD_IMPL_UTIL_C_
#define GLAD_IMPL_UTIL_C_

#ifdef _MSC_VER
#define GLAD_IMPL_UTIL_SSCANF sscanf_s
#else
#define GLAD_IMPL_UTIL_SSCANF sscanf
#endif

#endif /* GLAD_IMPL_UTIL_C_ */

#ifdef __cplusplus
extern "C" {
#endif








static void glad_gl_load_GL_VERSION_1_0(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_1_0) return;
    context->BlendFunc = (PFNGLBLENDFUNCPROC) load(userptr, "glBlendFunc");
    context->Clear = (PFNGLCLEARPROC) load(userptr, "glClear");
    context->ClearColor = (PFNGLCLEARCOLORPROC) load(userptr, "glClearColor");
    context->ClearDepth = (PFNGLCLEARDEPTHPROC) load(userptr, "glClearDepth");
    context->ClearStencil = (PFNGLCLEARSTENCILPROC) load(userptr, "glClearStencil");
    context->ColorMask = (PFNGLCOLORMASKPROC) load(userptr, "glColorMask");
    context->CullFace = (PFNGLCULLFACEPROC) load(userptr, "glCullFace");
    context->DepthFunc = (PFNGLDEPTHFUNCPROC) load(userptr, "glDepthFunc");
    context->DepthMask = (PFNGLDEPTHMASKPROC) load(userptr, "glDepthMask");
    context->DepthRange = (PFNGLDEPTHRANGEPROC) load(userptr, "glDepthRange");
    context->Disable = (PFNGLDISABLEPROC) load(userptr, "glDisable");
    context->DrawBuffer = (PFNGLDRAWBUFFERPROC) load(userptr, "glDrawBuffer");
    context->Enable = (PFNGLENABLEPROC) load(userptr, "glEnable");
    context->Finish = (PFNGLFINISHPROC) load(userptr, "glFinish");
    context->Flush = (PFNGLFLUSHPROC) load(userptr, "glFlush");
    context->FrontFace = (PFNGLFRONTFACEPROC) load(userptr, "glFrontFace");
    context->GetBooleanv = (PFNGLGETBOOLEANVPROC) load(userptr, "glGetBooleanv");
    context->GetDoublev = (PFNGLGETDOUBLEVPROC) load(userptr, "glGetDoublev");
    context->GetError = (PFNGLGETERRORPROC) load(userptr, "glGetError");
    context->GetFloatv = (PFNGLGETFLOATVPROC) load(userptr, "glGetFloatv");
    context->GetIntegerv = (PFNGLGETINTEGERVPROC) load(userptr, "glGetIntegerv");
    context->GetString = (PFNGLGETSTRINGPROC) load(userptr, "glGetString");
    context->GetTexImage = (PFNGLGETTEXIMAGEPROC) load(userptr, "glGetTexImage");
    context->GetTexLevelParameterfv = (PFNGLGETTEXLEVELPARAMETERFVPROC) load(userptr, "glGetTexLevelParameterfv");
    context->GetTexLevelParameteriv = (PFNGLGETTEXLEVELPARAMETERIVPROC) load(userptr, "glGetTexLevelParameteriv");
    context->GetTexParameterfv = (PFNGLGETTEXPARAMETERFVPROC) load(userptr, "glGetTexParameterfv");
    context->GetTexParameteriv = (PFNGLGETTEXPARAMETERIVPROC) load(userptr, "glGetTexParameteriv");
    context->Hint = (PFNGLHINTPROC) load(userptr, "glHint");
    context->IsEnabled = (PFNGLISENABLEDPROC) load(userptr, "glIsEnabled");
    context->LineWidth = (PFNGLLINEWIDTHPROC) load(userptr, "glLineWidth");
    context->LogicOp = (PFNGLLOGICOPPROC) load(userptr, "glLogicOp");
    context->PixelStoref = (PFNGLPIXELSTOREFPROC) load(userptr, "glPixelStoref");
    context->PixelStorei = (PFNGLPIXELSTOREIPROC) load(userptr, "glPixelStorei");
    context->PointSize = (PFNGLPOINTSIZEPROC) load(userptr, "glPointSize");
    context->PolygonMode = (PFNGLPOLYGONMODEPROC) load(userptr, "glPolygonMode");
    context->ReadBuffer = (PFNGLREADBUFFERPROC) load(userptr, "glReadBuffer");
    context->ReadPixels = (PFNGLREADPIXELSPROC) load(userptr, "glReadPixels");
    context->Scissor = (PFNGLSCISSORPROC) load(userptr, "glScissor");
    context->StencilFunc = (PFNGLSTENCILFUNCPROC) load(userptr, "glStencilFunc");
    context->StencilMask = (PFNGLSTENCILMASKPROC) load(userptr, "glStencilMask");
    context->StencilOp = (PFNGLSTENCILOPPROC) load(userptr, "glStencilOp");
    context->TexImage1D = (PFNGLTEXIMAGE1DPROC) load(userptr, "glTexImage1D");
    context->TexImage2D = (PFNGLTEXIMAGE2DPROC) load(userptr, "glTexImage2D");
    context->TexParameterf = (PFNGLTEXPARAMETERFPROC) load(userptr, "glTexParameterf");
    context->TexParameterfv = (PFNGLTEXPARAMETERFVPROC) load(userptr, "glTexParameterfv");
    context->TexParameteri = (PFNGLTEXPARAMETERIPROC) load(userptr, "glTexParameteri");
    context->TexParameteriv = (PFNGLTEXPARAMETERIVPROC) load(userptr, "glTexParameteriv");
    context->Viewport = (PFNGLVIEWPORTPROC) load(userptr, "glViewport");
}
static void glad_gl_load_GL_VERSION_1_1(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_1_1) return;
    context->BindTexture = (PFNGLBINDTEXTUREPROC) load(userptr, "glBindTexture");
    context->CopyTexImage1D = (PFNGLCOPYTEXIMAGE1DPROC) load(userptr, "glCopyTexImage1D");
    context->CopyTexImage2D = (PFNGLCOPYTEXIMAGE2DPROC) load(userptr, "glCopyTexImage2D");
    context->CopyTexSubImage1D = (PFNGLCOPYTEXSUBIMAGE1DPROC) load(userptr, "glCopyTexSubImage1D");
    context->CopyTexSubImage2D = (PFNGLCOPYTEXSUBIMAGE2DPROC) load(userptr, "glCopyTexSubImage2D");
    context->DeleteTextures = (PFNGLDELETETEXTURESPROC) load(userptr, "glDeleteTextures");
    context->DrawArrays = (PFNGLDRAWARRAYSPROC) load(userptr, "glDrawArrays");
    context->DrawElements = (PFNGLDRAWELEMENTSPROC) load(userptr, "glDrawElements");
    context->GenTextures = (PFNGLGENTEXTURESPROC) load(userptr, "glGenTextures");
    context->GetPointerv = (PFNGLGETPOINTERVPROC) load(userptr, "glGetPointerv");
    context->IsTexture = (PFNGLISTEXTUREPROC) load(userptr, "glIsTexture");
    context->PolygonOffset = (PFNGLPOLYGONOFFSETPROC) load(userptr, "glPolygonOffset");
    context->TexSubImage1D = (PFNGLTEXSUBIMAGE1DPROC) load(userptr, "glTexSubImage1D");
    context->TexSubImage2D = (PFNGLTEXSUBIMAGE2DPROC) load(userptr, "glTexSubImage2D");
}
static void glad_gl_load_GL_VERSION_1_2(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_1_2) return;
    context->CopyTexSubImage3D = (PFNGLCOPYTEXSUBIMAGE3DPROC) load(userptr, "glCopyTexSubImage3D");
    context->DrawRangeElements = (PFNGLDRAWRANGEELEMENTSPROC) load(userptr, "glDrawRangeElements");
    context->TexImage3D = (PFNGLTEXIMAGE3DPROC) load(userptr, "glTexImage3D");
    context->TexSubImage3D = (PFNGLTEXSUBIMAGE3DPROC) load(userptr, "glTexSubImage3D");
}
static void glad_gl_load_GL_VERSION_1_3(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_1_3) return;
    context->ActiveTexture = (PFNGLACTIVETEXTUREPROC) load(userptr, "glActiveTexture");
    context->CompressedTexImage1D = (PFNGLCOMPRESSEDTEXIMAGE1DPROC) load(userptr, "glCompressedTexImage1D");
    context->CompressedTexImage2D = (PFNGLCOMPRESSEDTEXIMAGE2DPROC) load(userptr, "glCompressedTexImage2D");
    context->CompressedTexImage3D = (PFNGLCOMPRESSEDTEXIMAGE3DPROC) load(userptr, "glCompressedTexImage3D");
    context->CompressedTexSubImage1D = (PFNGLCOMPRESSEDTEXSUBIMAGE1DPROC) load(userptr, "glCompressedTexSubImage1D");
    context->CompressedTexSubImage2D = (PFNGLCOMPRESSEDTEXSUBIMAGE2DPROC) load(userptr, "glCompressedTexSubImage2D");
    context->CompressedTexSubImage3D = (PFNGLCOMPRESSEDTEXSUBIMAGE3DPROC) load(userptr, "glCompressedTexSubImage3D");
    context->GetCompressedTexImage = (PFNGLGETCOMPRESSEDTEXIMAGEPROC) load(userptr, "glGetCompressedTexImage");
    context->SampleCoverage = (PFNGLSAMPLECOVERAGEPROC) load(userptr, "glSampleCoverage");
}
static void glad_gl_load_GL_VERSION_1_4(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_1_4) return;
    context->BlendColor = (PFNGLBLENDCOLORPROC) load(userptr, "glBlendColor");
    context->BlendEquation = (PFNGLBLENDEQUATIONPROC) load(userptr, "glBlendEquation");
    context->BlendFuncSeparate = (PFNGLBLENDFUNCSEPARATEPROC) load(userptr, "glBlendFuncSeparate");
    context->MultiDrawArrays = (PFNGLMULTIDRAWARRAYSPROC) load(userptr, "glMultiDrawArrays");
    context->MultiDrawElements = (PFNGLMULTIDRAWELEMENTSPROC) load(userptr, "glMultiDrawElements");
    context->PointParameterf = (PFNGLPOINTPARAMETERFPROC) load(userptr, "glPointParameterf");
    context->PointParameterfv = (PFNGLPOINTPARAMETERFVPROC) load(userptr, "glPointParameterfv");
    context->PointParameteri = (PFNGLPOINTPARAMETERIPROC) load(userptr, "glPointParameteri");
    context->PointParameteriv = (PFNGLPOINTPARAMETERIVPROC) load(userptr, "glPointParameteriv");
}
static void glad_gl_load_GL_VERSION_1_5(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_1_5) return;
    context->BeginQuery = (PFNGLBEGINQUERYPROC) load(userptr, "glBeginQuery");
    context->BindBuffer = (PFNGLBINDBUFFERPROC) load(userptr, "glBindBuffer");
    context->BufferData = (PFNGLBUFFERDATAPROC) load(userptr, "glBufferData");
    context->BufferSubData = (PFNGLBUFFERSUBDATAPROC) load(userptr, "glBufferSubData");
    context->DeleteBuffers = (PFNGLDELETEBUFFERSPROC) load(userptr, "glDeleteBuffers");
    context->DeleteQueries = (PFNGLDELETEQUERIESPROC) load(userptr, "glDeleteQueries");
    context->EndQuery = (PFNGLENDQUERYPROC) load(userptr, "glEndQuery");
    context->GenBuffers = (PFNGLGENBUFFERSPROC) load(userptr, "glGenBuffers");
    context->GenQueries = (PFNGLGENQUERIESPROC) load(userptr, "glGenQueries");
    context->GetBufferParameteriv = (PFNGLGETBUFFERPARAMETERIVPROC) load(userptr, "glGetBufferParameteriv");
    context->GetBufferPointerv = (PFNGLGETBUFFERPOINTERVPROC) load(userptr, "glGetBufferPointerv");
    context->GetBufferSubData = (PFNGLGETBUFFERSUBDATAPROC) load(userptr, "glGetBufferSubData");
    context->GetQueryObjectiv = (PFNGLGETQUERYOBJECTIVPROC) load(userptr, "glGetQueryObjectiv");
    context->GetQueryObjectuiv = (PFNGLGETQUERYOBJECTUIVPROC) load(userptr, "glGetQueryObjectuiv");
    context->GetQueryiv = (PFNGLGETQUERYIVPROC) load(userptr, "glGetQueryiv");
    context->IsBuffer = (PFNGLISBUFFERPROC) load(userptr, "glIsBuffer");
    context->IsQuery = (PFNGLISQUERYPROC) load(userptr, "glIsQuery");
    context->MapBuffer = (PFNGLMAPBUFFERPROC) load(userptr, "glMapBuffer");
    context->UnmapBuffer = (PFNGLUNMAPBUFFERPROC) load(userptr, "glUnmapBuffer");
}
static void glad_gl_load_GL_VERSION_2_0(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_2_0) return;
    context->AttachShader = (PFNGLATTACHSHADERPROC) load(userptr, "glAttachShader");
    context->BindAttribLocation = (PFNGLBINDATTRIBLOCATIONPROC) load(userptr, "glBindAttribLocation");
    context->BlendEquationSeparate = (PFNGLBLENDEQUATIONSEPARATEPROC) load(userptr, "glBlendEquationSeparate");
    context->CompileShader = (PFNGLCOMPILESHADERPROC) load(userptr, "glCompileShader");
    context->CreateProgram = (PFNGLCREATEPROGRAMPROC) load(userptr, "glCreateProgram");
    context->CreateShader = (PFNGLCREATESHADERPROC) load(userptr, "glCreateShader");
    context->DeleteProgram = (PFNGLDELETEPROGRAMPROC) load(userptr, "glDeleteProgram");
    context->DeleteShader = (PFNGLDELETESHADERPROC) load(userptr, "glDeleteShader");
    context->DetachShader = (PFNGLDETACHSHADERPROC) load(userptr, "glDetachShader");
    context->DisableVertexAttribArray = (PFNGLDISABLEVERTEXATTRIBARRAYPROC) load(userptr, "glDisableVertexAttribArray");
    context->DrawBuffers = (PFNGLDRAWBUFFERSPROC) load(userptr, "glDrawBuffers");
    context->EnableVertexAttribArray = (PFNGLENABLEVERTEXATTRIBARRAYPROC) load(userptr, "glEnableVertexAttribArray");
    context->GetActiveAttrib = (PFNGLGETACTIVEATTRIBPROC) load(userptr, "glGetActiveAttrib");
    context->GetActiveUniform = (PFNGLGETACTIVEUNIFORMPROC) load(userptr, "glGetActiveUniform");
    context->GetAttachedShaders = (PFNGLGETATTACHEDSHADERSPROC) load(userptr, "glGetAttachedShaders");
    context->GetAttribLocation = (PFNGLGETATTRIBLOCATIONPROC) load(userptr, "glGetAttribLocation");
    context->GetProgramInfoLog = (PFNGLGETPROGRAMINFOLOGPROC) load(userptr, "glGetProgramInfoLog");
    context->GetProgramiv = (PFNGLGETPROGRAMIVPROC) load(userptr, "glGetProgramiv");
    context->GetShaderInfoLog = (PFNGLGETSHADERINFOLOGPROC) load(userptr, "glGetShaderInfoLog");
    context->GetShaderSource = (PFNGLGETSHADERSOURCEPROC) load(userptr, "glGetShaderSource");
    context->GetShaderiv = (PFNGLGETSHADERIVPROC) load(userptr, "glGetShaderiv");
    context->GetUniformLocation = (PFNGLGETUNIFORMLOCATIONPROC) load(userptr, "glGetUniformLocation");
    context->GetUniformfv = (PFNGLGETUNIFORMFVPROC) load(userptr, "glGetUniformfv");
    context->GetUniformiv = (PFNGLGETUNIFORMIVPROC) load(userptr, "glGetUniformiv");
    context->GetVertexAttribPointerv = (PFNGLGETVERTEXATTRIBPOINTERVPROC) load(userptr, "glGetVertexAttribPointerv");
    context->GetVertexAttribdv = (PFNGLGETVERTEXATTRIBDVPROC) load(userptr, "glGetVertexAttribdv");
    context->GetVertexAttribfv = (PFNGLGETVERTEXATTRIBFVPROC) load(userptr, "glGetVertexAttribfv");
    context->GetVertexAttribiv = (PFNGLGETVERTEXATTRIBIVPROC) load(userptr, "glGetVertexAttribiv");
    context->IsProgram = (PFNGLISPROGRAMPROC) load(userptr, "glIsProgram");
    context->IsShader = (PFNGLISSHADERPROC) load(userptr, "glIsShader");
    context->LinkProgram = (PFNGLLINKPROGRAMPROC) load(userptr, "glLinkProgram");
    context->ShaderSource = (PFNGLSHADERSOURCEPROC) load(userptr, "glShaderSource");
    context->StencilFuncSeparate = (PFNGLSTENCILFUNCSEPARATEPROC) load(userptr, "glStencilFuncSeparate");
    context->StencilMaskSeparate = (PFNGLSTENCILMASKSEPARATEPROC) load(userptr, "glStencilMaskSeparate");
    context->StencilOpSeparate = (PFNGLSTENCILOPSEPARATEPROC) load(userptr, "glStencilOpSeparate");
    context->Uniform1f = (PFNGLUNIFORM1FPROC) load(userptr, "glUniform1f");
    context->Uniform1fv = (PFNGLUNIFORM1FVPROC) load(userptr, "glUniform1fv");
    context->Uniform1i = (PFNGLUNIFORM1IPROC) load(userptr, "glUniform1i");
    context->Uniform1iv = (PFNGLUNIFORM1IVPROC) load(userptr, "glUniform1iv");
    context->Uniform2f = (PFNGLUNIFORM2FPROC) load(userptr, "glUniform2f");
    context->Uniform2fv = (PFNGLUNIFORM2FVPROC) load(userptr, "glUniform2fv");
    context->Uniform2i = (PFNGLUNIFORM2IPROC) load(userptr, "glUniform2i");
    context->Uniform2iv = (PFNGLUNIFORM2IVPROC) load(userptr, "glUniform2iv");
    context->Uniform3f = (PFNGLUNIFORM3FPROC) load(userptr, "glUniform3f");
    context->Uniform3fv = (PFNGLUNIFORM3FVPROC) load(userptr, "glUniform3fv");
    context->Uniform3i = (PFNGLUNIFORM3IPROC) load(userptr, "glUniform3i");
    context->Uniform3iv = (PFNGLUNIFORM3IVPROC) load(userptr, "glUniform3iv");
    context->Uniform4f = (PFNGLUNIFORM4FPROC) load(userptr, "glUniform4f");
    context->Uniform4fv = (PFNGLUNIFORM4FVPROC) load(userptr, "glUniform4fv");
    context->Uniform4i = (PFNGLUNIFORM4IPROC) load(userptr, "glUniform4i");
    context->Uniform4iv = (PFNGLUNIFORM4IVPROC) load(userptr, "glUniform4iv");
    context->UniformMatrix2fv = (PFNGLUNIFORMMATRIX2FVPROC) load(userptr, "glUniformMatrix2fv");
    context->UniformMatrix3fv = (PFNGLUNIFORMMATRIX3FVPROC) load(userptr, "glUniformMatrix3fv");
    context->UniformMatrix4fv = (PFNGLUNIFORMMATRIX4FVPROC) load(userptr, "glUniformMatrix4fv");
    context->UseProgram = (PFNGLUSEPROGRAMPROC) load(userptr, "glUseProgram");
    context->ValidateProgram = (PFNGLVALIDATEPROGRAMPROC) load(userptr, "glValidateProgram");
    context->VertexAttrib1d = (PFNGLVERTEXATTRIB1DPROC) load(userptr, "glVertexAttrib1d");
    context->VertexAttrib1dv = (PFNGLVERTEXATTRIB1DVPROC) load(userptr, "glVertexAttrib1dv");
    context->VertexAttrib1f = (PFNGLVERTEXATTRIB1FPROC) load(userptr, "glVertexAttrib1f");
    context->VertexAttrib1fv = (PFNGLVERTEXATTRIB1FVPROC) load(userptr, "glVertexAttrib1fv");
    context->VertexAttrib1s = (PFNGLVERTEXATTRIB1SPROC) load(userptr, "glVertexAttrib1s");
    context->VertexAttrib1sv = (PFNGLVERTEXATTRIB1SVPROC) load(userptr, "glVertexAttrib1sv");
    context->VertexAttrib2d = (PFNGLVERTEXATTRIB2DPROC) load(userptr, "glVertexAttrib2d");
    context->VertexAttrib2dv = (PFNGLVERTEXATTRIB2DVPROC) load(userptr, "glVertexAttrib2dv");
    context->VertexAttrib2f = (PFNGLVERTEXATTRIB2FPROC) load(userptr, "glVertexAttrib2f");
    context->VertexAttrib2fv = (PFNGLVERTEXATTRIB2FVPROC) load(userptr, "glVertexAttrib2fv");
    context->VertexAttrib2s = (PFNGLVERTEXATTRIB2SPROC) load(userptr, "glVertexAttrib2s");
    context->VertexAttrib2sv = (PFNGLVERTEXATTRIB2SVPROC) load(userptr, "glVertexAttrib2sv");
    context->VertexAttrib3d = (PFNGLVERTEXATTRIB3DPROC) load(userptr, "glVertexAttrib3d");
    context->VertexAttrib3dv = (PFNGLVERTEXATTRIB3DVPROC) load(userptr, "glVertexAttrib3dv");
    context->VertexAttrib3f = (PFNGLVERTEXATTRIB3FPROC) load(userptr, "glVertexAttrib3f");
    context->VertexAttrib3fv = (PFNGLVERTEXATTRIB3FVPROC) load(userptr, "glVertexAttrib3fv");
    context->VertexAttrib3s = (PFNGLVERTEXATTRIB3SPROC) load(userptr, "glVertexAttrib3s");
    context->VertexAttrib3sv = (PFNGLVERTEXATTRIB3SVPROC) load(userptr, "glVertexAttrib3sv");
    context->VertexAttrib4Nbv = (PFNGLVERTEXATTRIB4NBVPROC) load(userptr, "glVertexAttrib4Nbv");
    context->VertexAttrib4Niv = (PFNGLVERTEXATTRIB4NIVPROC) load(userptr, "glVertexAttrib4Niv");
    context->VertexAttrib4Nsv = (PFNGLVERTEXATTRIB4NSVPROC) load(userptr, "glVertexAttrib4Nsv");
    context->VertexAttrib4Nub = (PFNGLVERTEXATTRIB4NUBPROC) load(userptr, "glVertexAttrib4Nub");
    context->VertexAttrib4Nubv = (PFNGLVERTEXATTRIB4NUBVPROC) load(userptr, "glVertexAttrib4Nubv");
    context->VertexAttrib4Nuiv = (PFNGLVERTEXATTRIB4NUIVPROC) load(userptr, "glVertexAttrib4Nuiv");
    context->VertexAttrib4Nusv = (PFNGLVERTEXATTRIB4NUSVPROC) load(userptr, "glVertexAttrib4Nusv");
    context->VertexAttrib4bv = (PFNGLVERTEXATTRIB4BVPROC) load(userptr, "glVertexAttrib4bv");
    context->VertexAttrib4d = (PFNGLVERTEXATTRIB4DPROC) load(userptr, "glVertexAttrib4d");
    context->VertexAttrib4dv = (PFNGLVERTEXATTRIB4DVPROC) load(userptr, "glVertexAttrib4dv");
    context->VertexAttrib4f = (PFNGLVERTEXATTRIB4FPROC) load(userptr, "glVertexAttrib4f");
    context->VertexAttrib4fv = (PFNGLVERTEXATTRIB4FVPROC) load(userptr, "glVertexAttrib4fv");
    context->VertexAttrib4iv = (PFNGLVERTEXATTRIB4IVPROC) load(userptr, "glVertexAttrib4iv");
    context->VertexAttrib4s = (PFNGLVERTEXATTRIB4SPROC) load(userptr, "glVertexAttrib4s");
    context->VertexAttrib4sv = (PFNGLVERTEXATTRIB4SVPROC) load(userptr, "glVertexAttrib4sv");
    context->VertexAttrib4ubv = (PFNGLVERTEXATTRIB4UBVPROC) load(userptr, "glVertexAttrib4ubv");
    context->VertexAttrib4uiv = (PFNGLVERTEXATTRIB4UIVPROC) load(userptr, "glVertexAttrib4uiv");
    context->VertexAttrib4usv = (PFNGLVERTEXATTRIB4USVPROC) load(userptr, "glVertexAttrib4usv");
    context->VertexAttribPointer = (PFNGLVERTEXATTRIBPOINTERPROC) load(userptr, "glVertexAttribPointer");
}
static void glad_gl_load_GL_VERSION_2_1(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_2_1) return;
    context->UniformMatrix2x3fv = (PFNGLUNIFORMMATRIX2X3FVPROC) load(userptr, "glUniformMatrix2x3fv");
    context->UniformMatrix2x4fv = (PFNGLUNIFORMMATRIX2X4FVPROC) load(userptr, "glUniformMatrix2x4fv");
    context->UniformMatrix3x2fv = (PFNGLUNIFORMMATRIX3X2FVPROC) load(userptr, "glUniformMatrix3x2fv");
    context->UniformMatrix3x4fv = (PFNGLUNIFORMMATRIX3X4FVPROC) load(userptr, "glUniformMatrix3x4fv");
    context->UniformMatrix4x2fv = (PFNGLUNIFORMMATRIX4X2FVPROC) load(userptr, "glUniformMatrix4x2fv");
    context->UniformMatrix4x3fv = (PFNGLUNIFORMMATRIX4X3FVPROC) load(userptr, "glUniformMatrix4x3fv");
}
static void glad_gl_load_GL_VERSION_3_0(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_3_0) return;
    context->BeginConditionalRender = (PFNGLBEGINCONDITIONALRENDERPROC) load(userptr, "glBeginConditionalRender");
    context->BeginTransformFeedback = (PFNGLBEGINTRANSFORMFEEDBACKPROC) load(userptr, "glBeginTransformFeedback");
    context->BindBufferBase = (PFNGLBINDBUFFERBASEPROC) load(userptr, "glBindBufferBase");
    context->BindBufferRange = (PFNGLBINDBUFFERRANGEPROC) load(userptr, "glBindBufferRange");
    context->BindFragDataLocation = (PFNGLBINDFRAGDATALOCATIONPROC) load(userptr, "glBindFragDataLocation");
    context->BindFramebuffer = (PFNGLBINDFRAMEBUFFERPROC) load(userptr, "glBindFramebuffer");
    context->BindRenderbuffer = (PFNGLBINDRENDERBUFFERPROC) load(userptr, "glBindRenderbuffer");
    context->BindVertexArray = (PFNGLBINDVERTEXARRAYPROC) load(userptr, "glBindVertexArray");
    context->BlitFramebuffer = (PFNGLBLITFRAMEBUFFERPROC) load(userptr, "glBlitFramebuffer");
    context->CheckFramebufferStatus = (PFNGLCHECKFRAMEBUFFERSTATUSPROC) load(userptr, "glCheckFramebufferStatus");
    context->ClampColor = (PFNGLCLAMPCOLORPROC) load(userptr, "glClampColor");
    context->ClearBufferfi = (PFNGLCLEARBUFFERFIPROC) load(userptr, "glClearBufferfi");
    context->ClearBufferfv = (PFNGLCLEARBUFFERFVPROC) load(userptr, "glClearBufferfv");
    context->ClearBufferiv = (PFNGLCLEARBUFFERIVPROC) load(userptr, "glClearBufferiv");
    context->ClearBufferuiv = (PFNGLCLEARBUFFERUIVPROC) load(userptr, "glClearBufferuiv");
    context->ColorMaski = (PFNGLCOLORMASKIPROC) load(userptr, "glColorMaski");
    context->DeleteFramebuffers = (PFNGLDELETEFRAMEBUFFERSPROC) load(userptr, "glDeleteFramebuffers");
    context->DeleteRenderbuffers = (PFNGLDELETERENDERBUFFERSPROC) load(userptr, "glDeleteRenderbuffers");
    context->DeleteVertexArrays = (PFNGLDELETEVERTEXARRAYSPROC) load(userptr, "glDeleteVertexArrays");
    context->Disablei = (PFNGLDISABLEIPROC) load(userptr, "glDisablei");
    context->Enablei = (PFNGLENABLEIPROC) load(userptr, "glEnablei");
    context->EndConditionalRender = (PFNGLENDCONDITIONALRENDERPROC) load(userptr, "glEndConditionalRender");
    context->EndTransformFeedback = (PFNGLENDTRANSFORMFEEDBACKPROC) load(userptr, "glEndTransformFeedback");
    context->FlushMappedBufferRange = (PFNGLFLUSHMAPPEDBUFFERRANGEPROC) load(userptr, "glFlushMappedBufferRange");
    context->FramebufferRenderbuffer = (PFNGLFRAMEBUFFERRENDERBUFFERPROC) load(userptr, "glFramebufferRenderbuffer");
    context->FramebufferTexture1D = (PFNGLFRAMEBUFFERTEXTURE1DPROC) load(userptr, "glFramebufferTexture1D");
    context->FramebufferTexture2D = (PFNGLFRAMEBUFFERTEXTURE2DPROC) load(userptr, "glFramebufferTexture2D");
    context->FramebufferTexture3D = (PFNGLFRAMEBUFFERTEXTURE3DPROC) load(userptr, "glFramebufferTexture3D");
    context->FramebufferTextureLayer = (PFNGLFRAMEBUFFERTEXTURELAYERPROC) load(userptr, "glFramebufferTextureLayer");
    context->GenFramebuffers = (PFNGLGENFRAMEBUFFERSPROC) load(userptr, "glGenFramebuffers");
    context->GenRenderbuffers = (PFNGLGENRENDERBUFFERSPROC) load(userptr, "glGenRenderbuffers");
    context->GenVertexArrays = (PFNGLGENVERTEXARRAYSPROC) load(userptr, "glGenVertexArrays");
    context->GenerateMipmap = (PFNGLGENERATEMIPMAPPROC) load(userptr, "glGenerateMipmap");
    context->GetBooleani_v = (PFNGLGETBOOLEANI_VPROC) load(userptr, "glGetBooleani_v");
    context->GetFragDataLocation = (PFNGLGETFRAGDATALOCATIONPROC) load(userptr, "glGetFragDataLocation");
    context->GetFramebufferAttachmentParameteriv = (PFNGLGETFRAMEBUFFERATTACHMENTPARAMETERIVPROC) load(userptr, "glGetFramebufferAttachmentParameteriv");
    context->GetIntegeri_v = (PFNGLGETINTEGERI_VPROC) load(userptr, "glGetIntegeri_v");
    context->GetRenderbufferParameteriv = (PFNGLGETRENDERBUFFERPARAMETERIVPROC) load(userptr, "glGetRenderbufferParameteriv");
    context->GetStringi = (PFNGLGETSTRINGIPROC) load(userptr, "glGetStringi");
    context->GetTexParameterIiv = (PFNGLGETTEXPARAMETERIIVPROC) load(userptr, "glGetTexParameterIiv");
    context->GetTexParameterIuiv = (PFNGLGETTEXPARAMETERIUIVPROC) load(userptr, "glGetTexParameterIuiv");
    context->GetTransformFeedbackVarying = (PFNGLGETTRANSFORMFEEDBACKVARYINGPROC) load(userptr, "glGetTransformFeedbackVarying");
    context->GetUniformuiv = (PFNGLGETUNIFORMUIVPROC) load(userptr, "glGetUniformuiv");
    context->GetVertexAttribIiv = (PFNGLGETVERTEXATTRIBIIVPROC) load(userptr, "glGetVertexAttribIiv");
    context->GetVertexAttribIuiv = (PFNGLGETVERTEXATTRIBIUIVPROC) load(userptr, "glGetVertexAttribIuiv");
    context->IsEnabledi = (PFNGLISENABLEDIPROC) load(userptr, "glIsEnabledi");
    context->IsFramebuffer = (PFNGLISFRAMEBUFFERPROC) load(userptr, "glIsFramebuffer");
    context->IsRenderbuffer = (PFNGLISRENDERBUFFERPROC) load(userptr, "glIsRenderbuffer");
    context->IsVertexArray = (PFNGLISVERTEXARRAYPROC) load(userptr, "glIsVertexArray");
    context->MapBufferRange = (PFNGLMAPBUFFERRANGEPROC) load(userptr, "glMapBufferRange");
    context->RenderbufferStorage = (PFNGLRENDERBUFFERSTORAGEPROC) load(userptr, "glRenderbufferStorage");
    context->RenderbufferStorageMultisample = (PFNGLRENDERBUFFERSTORAGEMULTISAMPLEPROC) load(userptr, "glRenderbufferStorageMultisample");
    context->TexParameterIiv = (PFNGLTEXPARAMETERIIVPROC) load(userptr, "glTexParameterIiv");
    context->TexParameterIuiv = (PFNGLTEXPARAMETERIUIVPROC) load(userptr, "glTexParameterIuiv");
    context->TransformFeedbackVaryings = (PFNGLTRANSFORMFEEDBACKVARYINGSPROC) load(userptr, "glTransformFeedbackVaryings");
    context->Uniform1ui = (PFNGLUNIFORM1UIPROC) load(userptr, "glUniform1ui");
    context->Uniform1uiv = (PFNGLUNIFORM1UIVPROC) load(userptr, "glUniform1uiv");
    context->Uniform2ui = (PFNGLUNIFORM2UIPROC) load(userptr, "glUniform2ui");
    context->Uniform2uiv = (PFNGLUNIFORM2UIVPROC) load(userptr, "glUniform2uiv");
    context->Uniform3ui = (PFNGLUNIFORM3UIPROC) load(userptr, "glUniform3ui");
    context->Uniform3uiv = (PFNGLUNIFORM3UIVPROC) load(userptr, "glUniform3uiv");
    context->Uniform4ui = (PFNGLUNIFORM4UIPROC) load(userptr, "glUniform4ui");
    context->Uniform4uiv = (PFNGLUNIFORM4UIVPROC) load(userptr, "glUniform4uiv");
    context->VertexAttribI1i = (PFNGLVERTEXATTRIBI1IPROC) load(userptr, "glVertexAttribI1i");
    context->VertexAttribI1iv = (PFNGLVERTEXATTRIBI1IVPROC) load(userptr, "glVertexAttribI1iv");
    context->VertexAttribI1ui = (PFNGLVERTEXATTRIBI1UIPROC) load(userptr, "glVertexAttribI1ui");
    context->VertexAttribI1uiv = (PFNGLVERTEXATTRIBI1UIVPROC) load(userptr, "glVertexAttribI1uiv");
    context->VertexAttribI2i = (PFNGLVERTEXATTRIBI2IPROC) load(userptr, "glVertexAttribI2i");
    context->VertexAttribI2iv = (PFNGLVERTEXATTRIBI2IVPROC) load(userptr, "glVertexAttribI2iv");
    context->VertexAttribI2ui = (PFNGLVERTEXATTRIBI2UIPROC) load(userptr, "glVertexAttribI2ui");
    context->VertexAttribI2uiv = (PFNGLVERTEXATTRIBI2UIVPROC) load(userptr, "glVertexAttribI2uiv");
    context->VertexAttribI3i = (PFNGLVERTEXATTRIBI3IPROC) load(userptr, "glVertexAttribI3i");
    context->VertexAttribI3iv = (PFNGLVERTEXATTRIBI3IVPROC) load(userptr, "glVertexAttribI3iv");
    context->VertexAttribI3ui = (PFNGLVERTEXATTRIBI3UIPROC) load(userptr, "glVertexAttribI3ui");
    context->VertexAttribI3uiv = (PFNGLVERTEXATTRIBI3UIVPROC) load(userptr, "glVertexAttribI3uiv");
    context->VertexAttribI4bv = (PFNGLVERTEXATTRIBI4BVPROC) load(userptr, "glVertexAttribI4bv");
    context->VertexAttribI4i = (PFNGLVERTEXATTRIBI4IPROC) load(userptr, "glVertexAttribI4i");
    context->VertexAttribI4iv = (PFNGLVERTEXATTRIBI4IVPROC) load(userptr, "glVertexAttribI4iv");
    context->VertexAttribI4sv = (PFNGLVERTEXATTRIBI4SVPROC) load(userptr, "glVertexAttribI4sv");
    context->VertexAttribI4ubv = (PFNGLVERTEXATTRIBI4UBVPROC) load(userptr, "glVertexAttribI4ubv");
    context->VertexAttribI4ui = (PFNGLVERTEXATTRIBI4UIPROC) load(userptr, "glVertexAttribI4ui");
    context->VertexAttribI4uiv = (PFNGLVERTEXATTRIBI4UIVPROC) load(userptr, "glVertexAttribI4uiv");
    context->VertexAttribI4usv = (PFNGLVERTEXATTRIBI4USVPROC) load(userptr, "glVertexAttribI4usv");
    context->VertexAttribIPointer = (PFNGLVERTEXATTRIBIPOINTERPROC) load(userptr, "glVertexAttribIPointer");
}
static void glad_gl_load_GL_VERSION_3_1(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_3_1) return;
    context->BindBufferBase = (PFNGLBINDBUFFERBASEPROC) load(userptr, "glBindBufferBase");
    context->BindBufferRange = (PFNGLBINDBUFFERRANGEPROC) load(userptr, "glBindBufferRange");
    context->CopyBufferSubData = (PFNGLCOPYBUFFERSUBDATAPROC) load(userptr, "glCopyBufferSubData");
    context->DrawArraysInstanced = (PFNGLDRAWARRAYSINSTANCEDPROC) load(userptr, "glDrawArraysInstanced");
    context->DrawElementsInstanced = (PFNGLDRAWELEMENTSINSTANCEDPROC) load(userptr, "glDrawElementsInstanced");
    context->GetActiveUniformBlockName = (PFNGLGETACTIVEUNIFORMBLOCKNAMEPROC) load(userptr, "glGetActiveUniformBlockName");
    context->GetActiveUniformBlockiv = (PFNGLGETACTIVEUNIFORMBLOCKIVPROC) load(userptr, "glGetActiveUniformBlockiv");
    context->GetActiveUniformName = (PFNGLGETACTIVEUNIFORMNAMEPROC) load(userptr, "glGetActiveUniformName");
    context->GetActiveUniformsiv = (PFNGLGETACTIVEUNIFORMSIVPROC) load(userptr, "glGetActiveUniformsiv");
    context->GetIntegeri_v = (PFNGLGETINTEGERI_VPROC) load(userptr, "glGetIntegeri_v");
    context->GetUniformBlockIndex = (PFNGLGETUNIFORMBLOCKINDEXPROC) load(userptr, "glGetUniformBlockIndex");
    context->GetUniformIndices = (PFNGLGETUNIFORMINDICESPROC) load(userptr, "glGetUniformIndices");
    context->PrimitiveRestartIndex = (PFNGLPRIMITIVERESTARTINDEXPROC) load(userptr, "glPrimitiveRestartIndex");
    context->TexBuffer = (PFNGLTEXBUFFERPROC) load(userptr, "glTexBuffer");
    context->UniformBlockBinding = (PFNGLUNIFORMBLOCKBINDINGPROC) load(userptr, "glUniformBlockBinding");
}
static void glad_gl_load_GL_VERSION_3_2(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_3_2) return;
    context->ClientWaitSync = (PFNGLCLIENTWAITSYNCPROC) load(userptr, "glClientWaitSync");
    context->DeleteSync = (PFNGLDELETESYNCPROC) load(userptr, "glDeleteSync");
    context->DrawElementsBaseVertex = (PFNGLDRAWELEMENTSBASEVERTEXPROC) load(userptr, "glDrawElementsBaseVertex");
    context->DrawElementsInstancedBaseVertex = (PFNGLDRAWELEMENTSINSTANCEDBASEVERTEXPROC) load(userptr, "glDrawElementsInstancedBaseVertex");
    context->DrawRangeElementsBaseVertex = (PFNGLDRAWRANGEELEMENTSBASEVERTEXPROC) load(userptr, "glDrawRangeElementsBaseVertex");
    context->FenceSync = (PFNGLFENCESYNCPROC) load(userptr, "glFenceSync");
    context->FramebufferTexture = (PFNGLFRAMEBUFFERTEXTUREPROC) load(userptr, "glFramebufferTexture");
    context->GetBufferParameteri64v = (PFNGLGETBUFFERPARAMETERI64VPROC) load(userptr, "glGetBufferParameteri64v");
    context->GetInteger64i_v = (PFNGLGETINTEGER64I_VPROC) load(userptr, "glGetInteger64i_v");
    context->GetInteger64v = (PFNGLGETINTEGER64VPROC) load(userptr, "glGetInteger64v");
    context->GetMultisamplefv = (PFNGLGETMULTISAMPLEFVPROC) load(userptr, "glGetMultisamplefv");
    context->GetSynciv = (PFNGLGETSYNCIVPROC) load(userptr, "glGetSynciv");
    context->IsSync = (PFNGLISSYNCPROC) load(userptr, "glIsSync");
    context->MultiDrawElementsBaseVertex = (PFNGLMULTIDRAWELEMENTSBASEVERTEXPROC) load(userptr, "glMultiDrawElementsBaseVertex");
    context->ProvokingVertex = (PFNGLPROVOKINGVERTEXPROC) load(userptr, "glProvokingVertex");
    context->SampleMaski = (PFNGLSAMPLEMASKIPROC) load(userptr, "glSampleMaski");
    context->TexImage2DMultisample = (PFNGLTEXIMAGE2DMULTISAMPLEPROC) load(userptr, "glTexImage2DMultisample");
    context->TexImage3DMultisample = (PFNGLTEXIMAGE3DMULTISAMPLEPROC) load(userptr, "glTexImage3DMultisample");
    context->WaitSync = (PFNGLWAITSYNCPROC) load(userptr, "glWaitSync");
}
static void glad_gl_load_GL_VERSION_3_3(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_3_3) return;
    context->BindFragDataLocationIndexed = (PFNGLBINDFRAGDATALOCATIONINDEXEDPROC) load(userptr, "glBindFragDataLocationIndexed");
    context->BindSampler = (PFNGLBINDSAMPLERPROC) load(userptr, "glBindSampler");
    context->DeleteSamplers = (PFNGLDELETESAMPLERSPROC) load(userptr, "glDeleteSamplers");
    context->GenSamplers = (PFNGLGENSAMPLERSPROC) load(userptr, "glGenSamplers");
    context->GetFragDataIndex = (PFNGLGETFRAGDATAINDEXPROC) load(userptr, "glGetFragDataIndex");
    context->GetQueryObjecti64v = (PFNGLGETQUERYOBJECTI64VPROC) load(userptr, "glGetQueryObjecti64v");
    context->GetQueryObjectui64v = (PFNGLGETQUERYOBJECTUI64VPROC) load(userptr, "glGetQueryObjectui64v");
    context->GetSamplerParameterIiv = (PFNGLGETSAMPLERPARAMETERIIVPROC) load(userptr, "glGetSamplerParameterIiv");
    context->GetSamplerParameterIuiv = (PFNGLGETSAMPLERPARAMETERIUIVPROC) load(userptr, "glGetSamplerParameterIuiv");
    context->GetSamplerParameterfv = (PFNGLGETSAMPLERPARAMETERFVPROC) load(userptr, "glGetSamplerParameterfv");
    context->GetSamplerParameteriv = (PFNGLGETSAMPLERPARAMETERIVPROC) load(userptr, "glGetSamplerParameteriv");
    context->IsSampler = (PFNGLISSAMPLERPROC) load(userptr, "glIsSampler");
    context->QueryCounter = (PFNGLQUERYCOUNTERPROC) load(userptr, "glQueryCounter");
    context->SamplerParameterIiv = (PFNGLSAMPLERPARAMETERIIVPROC) load(userptr, "glSamplerParameterIiv");
    context->SamplerParameterIuiv = (PFNGLSAMPLERPARAMETERIUIVPROC) load(userptr, "glSamplerParameterIuiv");
    context->SamplerParameterf = (PFNGLSAMPLERPARAMETERFPROC) load(userptr, "glSamplerParameterf");
    context->SamplerParameterfv = (PFNGLSAMPLERPARAMETERFVPROC) load(userptr, "glSamplerParameterfv");
    context->SamplerParameteri = (PFNGLSAMPLERPARAMETERIPROC) load(userptr, "glSamplerParameteri");
    context->SamplerParameteriv = (PFNGLSAMPLERPARAMETERIVPROC) load(userptr, "glSamplerParameteriv");
    context->VertexAttribDivisor = (PFNGLVERTEXATTRIBDIVISORPROC) load(userptr, "glVertexAttribDivisor");
    context->VertexAttribP1ui = (PFNGLVERTEXATTRIBP1UIPROC) load(userptr, "glVertexAttribP1ui");
    context->VertexAttribP1uiv = (PFNGLVERTEXATTRIBP1UIVPROC) load(userptr, "glVertexAttribP1uiv");
    context->VertexAttribP2ui = (PFNGLVERTEXATTRIBP2UIPROC) load(userptr, "glVertexAttribP2ui");
    context->VertexAttribP2uiv = (PFNGLVERTEXATTRIBP2UIVPROC) load(userptr, "glVertexAttribP2uiv");
    context->VertexAttribP3ui = (PFNGLVERTEXATTRIBP3UIPROC) load(userptr, "glVertexAttribP3ui");
    context->VertexAttribP3uiv = (PFNGLVERTEXATTRIBP3UIVPROC) load(userptr, "glVertexAttribP3uiv");
    context->VertexAttribP4ui = (PFNGLVERTEXATTRIBP4UIPROC) load(userptr, "glVertexAttribP4ui");
    context->VertexAttribP4uiv = (PFNGLVERTEXATTRIBP4UIVPROC) load(userptr, "glVertexAttribP4uiv");
}
static void glad_gl_load_GL_VERSION_4_0(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_4_0) return;
    context->BeginQueryIndexed = (PFNGLBEGINQUERYINDEXEDPROC) load(userptr, "glBeginQueryIndexed");
    context->BindTransformFeedback = (PFNGLBINDTRANSFORMFEEDBACKPROC) load(userptr, "glBindTransformFeedback");
    context->BlendEquationSeparatei = (PFNGLBLENDEQUATIONSEPARATEIPROC) load(userptr, "glBlendEquationSeparatei");
    context->BlendEquationi = (PFNGLBLENDEQUATIONIPROC) load(userptr, "glBlendEquationi");
    context->BlendFuncSeparatei = (PFNGLBLENDFUNCSEPARATEIPROC) load(userptr, "glBlendFuncSeparatei");
    context->BlendFunci = (PFNGLBLENDFUNCIPROC) load(userptr, "glBlendFunci");
    context->DeleteTransformFeedbacks = (PFNGLDELETETRANSFORMFEEDBACKSPROC) load(userptr, "glDeleteTransformFeedbacks");
    context->DrawArraysIndirect = (PFNGLDRAWARRAYSINDIRECTPROC) load(userptr, "glDrawArraysIndirect");
    context->DrawElementsIndirect = (PFNGLDRAWELEMENTSINDIRECTPROC) load(userptr, "glDrawElementsIndirect");
    context->DrawTransformFeedback = (PFNGLDRAWTRANSFORMFEEDBACKPROC) load(userptr, "glDrawTransformFeedback");
    context->DrawTransformFeedbackStream = (PFNGLDRAWTRANSFORMFEEDBACKSTREAMPROC) load(userptr, "glDrawTransformFeedbackStream");
    context->EndQueryIndexed = (PFNGLENDQUERYINDEXEDPROC) load(userptr, "glEndQueryIndexed");
    context->GenTransformFeedbacks = (PFNGLGENTRANSFORMFEEDBACKSPROC) load(userptr, "glGenTransformFeedbacks");
    context->GetActiveSubroutineName = (PFNGLGETACTIVESUBROUTINENAMEPROC) load(userptr, "glGetActiveSubroutineName");
    context->GetActiveSubroutineUniformName = (PFNGLGETACTIVESUBROUTINEUNIFORMNAMEPROC) load(userptr, "glGetActiveSubroutineUniformName");
    context->GetActiveSubroutineUniformiv = (PFNGLGETACTIVESUBROUTINEUNIFORMIVPROC) load(userptr, "glGetActiveSubroutineUniformiv");
    context->GetProgramStageiv = (PFNGLGETPROGRAMSTAGEIVPROC) load(userptr, "glGetProgramStageiv");
    context->GetQueryIndexediv = (PFNGLGETQUERYINDEXEDIVPROC) load(userptr, "glGetQueryIndexediv");
    context->GetSubroutineIndex = (PFNGLGETSUBROUTINEINDEXPROC) load(userptr, "glGetSubroutineIndex");
    context->GetSubroutineUniformLocation = (PFNGLGETSUBROUTINEUNIFORMLOCATIONPROC) load(userptr, "glGetSubroutineUniformLocation");
    context->GetUniformSubroutineuiv = (PFNGLGETUNIFORMSUBROUTINEUIVPROC) load(userptr, "glGetUniformSubroutineuiv");
    context->GetUniformdv = (PFNGLGETUNIFORMDVPROC) load(userptr, "glGetUniformdv");
    context->IsTransformFeedback = (PFNGLISTRANSFORMFEEDBACKPROC) load(userptr, "glIsTransformFeedback");
    context->MinSampleShading = (PFNGLMINSAMPLESHADINGPROC) load(userptr, "glMinSampleShading");
    context->PatchParameterfv = (PFNGLPATCHPARAMETERFVPROC) load(userptr, "glPatchParameterfv");
    context->PatchParameteri = (PFNGLPATCHPARAMETERIPROC) load(userptr, "glPatchParameteri");
    context->PauseTransformFeedback = (PFNGLPAUSETRANSFORMFEEDBACKPROC) load(userptr, "glPauseTransformFeedback");
    context->ResumeTransformFeedback = (PFNGLRESUMETRANSFORMFEEDBACKPROC) load(userptr, "glResumeTransformFeedback");
    context->Uniform1d = (PFNGLUNIFORM1DPROC) load(userptr, "glUniform1d");
    context->Uniform1dv = (PFNGLUNIFORM1DVPROC) load(userptr, "glUniform1dv");
    context->Uniform2d = (PFNGLUNIFORM2DPROC) load(userptr, "glUniform2d");
    context->Uniform2dv = (PFNGLUNIFORM2DVPROC) load(userptr, "glUniform2dv");
    context->Uniform3d = (PFNGLUNIFORM3DPROC) load(userptr, "glUniform3d");
    context->Uniform3dv = (PFNGLUNIFORM3DVPROC) load(userptr, "glUniform3dv");
    context->Uniform4d = (PFNGLUNIFORM4DPROC) load(userptr, "glUniform4d");
    context->Uniform4dv = (PFNGLUNIFORM4DVPROC) load(userptr, "glUniform4dv");
    context->UniformMatrix2dv = (PFNGLUNIFORMMATRIX2DVPROC) load(userptr, "glUniformMatrix2dv");
    context->UniformMatrix2x3dv = (PFNGLUNIFORMMATRIX2X3DVPROC) load(userptr, "glUniformMatrix2x3dv");
    context->UniformMatrix2x4dv = (PFNGLUNIFORMMATRIX2X4DVPROC) load(userptr, "glUniformMatrix2x4dv");
    context->UniformMatrix3dv = (PFNGLUNIFORMMATRIX3DVPROC) load(userptr, "glUniformMatrix3dv");
    context->UniformMatrix3x2dv = (PFNGLUNIFORMMATRIX3X2DVPROC) load(userptr, "glUniformMatrix3x2dv");
    context->UniformMatrix3x4dv = (PFNGLUNIFORMMATRIX3X4DVPROC) load(userptr, "glUniformMatrix3x4dv");
    context->UniformMatrix4dv = (PFNGLUNIFORMMATRIX4DVPROC) load(userptr, "glUniformMatrix4dv");
    context->UniformMatrix4x2dv = (PFNGLUNIFORMMATRIX4X2DVPROC) load(userptr, "glUniformMatrix4x2dv");
    context->UniformMatrix4x3dv = (PFNGLUNIFORMMATRIX4X3DVPROC) load(userptr, "glUniformMatrix4x3dv");
    context->UniformSubroutinesuiv = (PFNGLUNIFORMSUBROUTINESUIVPROC) load(userptr, "glUniformSubroutinesuiv");
}
static void glad_gl_load_GL_VERSION_4_1(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_4_1) return;
    context->ActiveShaderProgram = (PFNGLACTIVESHADERPROGRAMPROC) load(userptr, "glActiveShaderProgram");
    context->BindProgramPipeline = (PFNGLBINDPROGRAMPIPELINEPROC) load(userptr, "glBindProgramPipeline");
    context->ClearDepthf = (PFNGLCLEARDEPTHFPROC) load(userptr, "glClearDepthf");
    context->CreateShaderProgramv = (PFNGLCREATESHADERPROGRAMVPROC) load(userptr, "glCreateShaderProgramv");
    context->DeleteProgramPipelines = (PFNGLDELETEPROGRAMPIPELINESPROC) load(userptr, "glDeleteProgramPipelines");
    context->DepthRangeArrayv = (PFNGLDEPTHRANGEARRAYVPROC) load(userptr, "glDepthRangeArrayv");
    context->DepthRangeIndexed = (PFNGLDEPTHRANGEINDEXEDPROC) load(userptr, "glDepthRangeIndexed");
    context->DepthRangef = (PFNGLDEPTHRANGEFPROC) load(userptr, "glDepthRangef");
    context->GenProgramPipelines = (PFNGLGENPROGRAMPIPELINESPROC) load(userptr, "glGenProgramPipelines");
    context->GetDoublei_v = (PFNGLGETDOUBLEI_VPROC) load(userptr, "glGetDoublei_v");
    context->GetFloati_v = (PFNGLGETFLOATI_VPROC) load(userptr, "glGetFloati_v");
    context->GetProgramBinary = (PFNGLGETPROGRAMBINARYPROC) load(userptr, "glGetProgramBinary");
    context->GetProgramPipelineInfoLog = (PFNGLGETPROGRAMPIPELINEINFOLOGPROC) load(userptr, "glGetProgramPipelineInfoLog");
    context->GetProgramPipelineiv = (PFNGLGETPROGRAMPIPELINEIVPROC) load(userptr, "glGetProgramPipelineiv");
    context->GetShaderPrecisionFormat = (PFNGLGETSHADERPRECISIONFORMATPROC) load(userptr, "glGetShaderPrecisionFormat");
    context->GetVertexAttribLdv = (PFNGLGETVERTEXATTRIBLDVPROC) load(userptr, "glGetVertexAttribLdv");
    context->IsProgramPipeline = (PFNGLISPROGRAMPIPELINEPROC) load(userptr, "glIsProgramPipeline");
    context->ProgramBinary = (PFNGLPROGRAMBINARYPROC) load(userptr, "glProgramBinary");
    context->ProgramParameteri = (PFNGLPROGRAMPARAMETERIPROC) load(userptr, "glProgramParameteri");
    context->ProgramUniform1d = (PFNGLPROGRAMUNIFORM1DPROC) load(userptr, "glProgramUniform1d");
    context->ProgramUniform1dv = (PFNGLPROGRAMUNIFORM1DVPROC) load(userptr, "glProgramUniform1dv");
    context->ProgramUniform1f = (PFNGLPROGRAMUNIFORM1FPROC) load(userptr, "glProgramUniform1f");
    context->ProgramUniform1fv = (PFNGLPROGRAMUNIFORM1FVPROC) load(userptr, "glProgramUniform1fv");
    context->ProgramUniform1i = (PFNGLPROGRAMUNIFORM1IPROC) load(userptr, "glProgramUniform1i");
    context->ProgramUniform1iv = (PFNGLPROGRAMUNIFORM1IVPROC) load(userptr, "glProgramUniform1iv");
    context->ProgramUniform1ui = (PFNGLPROGRAMUNIFORM1UIPROC) load(userptr, "glProgramUniform1ui");
    context->ProgramUniform1uiv = (PFNGLPROGRAMUNIFORM1UIVPROC) load(userptr, "glProgramUniform1uiv");
    context->ProgramUniform2d = (PFNGLPROGRAMUNIFORM2DPROC) load(userptr, "glProgramUniform2d");
    context->ProgramUniform2dv = (PFNGLPROGRAMUNIFORM2DVPROC) load(userptr, "glProgramUniform2dv");
    context->ProgramUniform2f = (PFNGLPROGRAMUNIFORM2FPROC) load(userptr, "glProgramUniform2f");
    context->ProgramUniform2fv = (PFNGLPROGRAMUNIFORM2FVPROC) load(userptr, "glProgramUniform2fv");
    context->ProgramUniform2i = (PFNGLPROGRAMUNIFORM2IPROC) load(userptr, "glProgramUniform2i");
    context->ProgramUniform2iv = (PFNGLPROGRAMUNIFORM2IVPROC) load(userptr, "glProgramUniform2iv");
    context->ProgramUniform2ui = (PFNGLPROGRAMUNIFORM2UIPROC) load(userptr, "glProgramUniform2ui");
    context->ProgramUniform2uiv = (PFNGLPROGRAMUNIFORM2UIVPROC) load(userptr, "glProgramUniform2uiv");
    context->ProgramUniform3d = (PFNGLPROGRAMUNIFORM3DPROC) load(userptr, "glProgramUniform3d");
    context->ProgramUniform3dv = (PFNGLPROGRAMUNIFORM3DVPROC) load(userptr, "glProgramUniform3dv");
    context->ProgramUniform3f = (PFNGLPROGRAMUNIFORM3FPROC) load(userptr, "glProgramUniform3f");
    context->ProgramUniform3fv = (PFNGLPROGRAMUNIFORM3FVPROC) load(userptr, "glProgramUniform3fv");
    context->ProgramUniform3i = (PFNGLPROGRAMUNIFORM3IPROC) load(userptr, "glProgramUniform3i");
    context->ProgramUniform3iv = (PFNGLPROGRAMUNIFORM3IVPROC) load(userptr, "glProgramUniform3iv");
    context->ProgramUniform3ui = (PFNGLPROGRAMUNIFORM3UIPROC) load(userptr, "glProgramUniform3ui");
    context->ProgramUniform3uiv = (PFNGLPROGRAMUNIFORM3UIVPROC) load(userptr, "glProgramUniform3uiv");
    context->ProgramUniform4d = (PFNGLPROGRAMUNIFORM4DPROC) load(userptr, "glProgramUniform4d");
    context->ProgramUniform4dv = (PFNGLPROGRAMUNIFORM4DVPROC) load(userptr, "glProgramUniform4dv");
    context->ProgramUniform4f = (PFNGLPROGRAMUNIFORM4FPROC) load(userptr, "glProgramUniform4f");
    context->ProgramUniform4fv = (PFNGLPROGRAMUNIFORM4FVPROC) load(userptr, "glProgramUniform4fv");
    context->ProgramUniform4i = (PFNGLPROGRAMUNIFORM4IPROC) load(userptr, "glProgramUniform4i");
    context->ProgramUniform4iv = (PFNGLPROGRAMUNIFORM4IVPROC) load(userptr, "glProgramUniform4iv");
    context->ProgramUniform4ui = (PFNGLPROGRAMUNIFORM4UIPROC) load(userptr, "glProgramUniform4ui");
    context->ProgramUniform4uiv = (PFNGLPROGRAMUNIFORM4UIVPROC) load(userptr, "glProgramUniform4uiv");
    context->ProgramUniformMatrix2dv = (PFNGLPROGRAMUNIFORMMATRIX2DVPROC) load(userptr, "glProgramUniformMatrix2dv");
    context->ProgramUniformMatrix2fv = (PFNGLPROGRAMUNIFORMMATRIX2FVPROC) load(userptr, "glProgramUniformMatrix2fv");
    context->ProgramUniformMatrix2x3dv = (PFNGLPROGRAMUNIFORMMATRIX2X3DVPROC) load(userptr, "glProgramUniformMatrix2x3dv");
    context->ProgramUniformMatrix2x3fv = (PFNGLPROGRAMUNIFORMMATRIX2X3FVPROC) load(userptr, "glProgramUniformMatrix2x3fv");
    context->ProgramUniformMatrix2x4dv = (PFNGLPROGRAMUNIFORMMATRIX2X4DVPROC) load(userptr, "glProgramUniformMatrix2x4dv");
    context->ProgramUniformMatrix2x4fv = (PFNGLPROGRAMUNIFORMMATRIX2X4FVPROC) load(userptr, "glProgramUniformMatrix2x4fv");
    context->ProgramUniformMatrix3dv = (PFNGLPROGRAMUNIFORMMATRIX3DVPROC) load(userptr, "glProgramUniformMatrix3dv");
    context->ProgramUniformMatrix3fv = (PFNGLPROGRAMUNIFORMMATRIX3FVPROC) load(userptr, "glProgramUniformMatrix3fv");
    context->ProgramUniformMatrix3x2dv = (PFNGLPROGRAMUNIFORMMATRIX3X2DVPROC) load(userptr, "glProgramUniformMatrix3x2dv");
    context->ProgramUniformMatrix3x2fv = (PFNGLPROGRAMUNIFORMMATRIX3X2FVPROC) load(userptr, "glProgramUniformMatrix3x2fv");
    context->ProgramUniformMatrix3x4dv = (PFNGLPROGRAMUNIFORMMATRIX3X4DVPROC) load(userptr, "glProgramUniformMatrix3x4dv");
    context->ProgramUniformMatrix3x4fv = (PFNGLPROGRAMUNIFORMMATRIX3X4FVPROC) load(userptr, "glProgramUniformMatrix3x4fv");
    context->ProgramUniformMatrix4dv = (PFNGLPROGRAMUNIFORMMATRIX4DVPROC) load(userptr, "glProgramUniformMatrix4dv");
    context->ProgramUniformMatrix4fv = (PFNGLPROGRAMUNIFORMMATRIX4FVPROC) load(userptr, "glProgramUniformMatrix4fv");
    context->ProgramUniformMatrix4x2dv = (PFNGLPROGRAMUNIFORMMATRIX4X2DVPROC) load(userptr, "glProgramUniformMatrix4x2dv");
    context->ProgramUniformMatrix4x2fv = (PFNGLPROGRAMUNIFORMMATRIX4X2FVPROC) load(userptr, "glProgramUniformMatrix4x2fv");
    context->ProgramUniformMatrix4x3dv = (PFNGLPROGRAMUNIFORMMATRIX4X3DVPROC) load(userptr, "glProgramUniformMatrix4x3dv");
    context->ProgramUniformMatrix4x3fv = (PFNGLPROGRAMUNIFORMMATRIX4X3FVPROC) load(userptr, "glProgramUniformMatrix4x3fv");
    context->ReleaseShaderCompiler = (PFNGLRELEASESHADERCOMPILERPROC) load(userptr, "glReleaseShaderCompiler");
    context->ScissorArrayv = (PFNGLSCISSORARRAYVPROC) load(userptr, "glScissorArrayv");
    context->ScissorIndexed = (PFNGLSCISSORINDEXEDPROC) load(userptr, "glScissorIndexed");
    context->ScissorIndexedv = (PFNGLSCISSORINDEXEDVPROC) load(userptr, "glScissorIndexedv");
    context->ShaderBinary = (PFNGLSHADERBINARYPROC) load(userptr, "glShaderBinary");
    context->UseProgramStages = (PFNGLUSEPROGRAMSTAGESPROC) load(userptr, "glUseProgramStages");
    context->ValidateProgramPipeline = (PFNGLVALIDATEPROGRAMPIPELINEPROC) load(userptr, "glValidateProgramPipeline");
    context->VertexAttribL1d = (PFNGLVERTEXATTRIBL1DPROC) load(userptr, "glVertexAttribL1d");
    context->VertexAttribL1dv = (PFNGLVERTEXATTRIBL1DVPROC) load(userptr, "glVertexAttribL1dv");
    context->VertexAttribL2d = (PFNGLVERTEXATTRIBL2DPROC) load(userptr, "glVertexAttribL2d");
    context->VertexAttribL2dv = (PFNGLVERTEXATTRIBL2DVPROC) load(userptr, "glVertexAttribL2dv");
    context->VertexAttribL3d = (PFNGLVERTEXATTRIBL3DPROC) load(userptr, "glVertexAttribL3d");
    context->VertexAttribL3dv = (PFNGLVERTEXATTRIBL3DVPROC) load(userptr, "glVertexAttribL3dv");
    context->VertexAttribL4d = (PFNGLVERTEXATTRIBL4DPROC) load(userptr, "glVertexAttribL4d");
    context->VertexAttribL4dv = (PFNGLVERTEXATTRIBL4DVPROC) load(userptr, "glVertexAttribL4dv");
    context->VertexAttribLPointer = (PFNGLVERTEXATTRIBLPOINTERPROC) load(userptr, "glVertexAttribLPointer");
    context->ViewportArrayv = (PFNGLVIEWPORTARRAYVPROC) load(userptr, "glViewportArrayv");
    context->ViewportIndexedf = (PFNGLVIEWPORTINDEXEDFPROC) load(userptr, "glViewportIndexedf");
    context->ViewportIndexedfv = (PFNGLVIEWPORTINDEXEDFVPROC) load(userptr, "glViewportIndexedfv");
}
static void glad_gl_load_GL_VERSION_4_2(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_4_2) return;
    context->BindImageTexture = (PFNGLBINDIMAGETEXTUREPROC) load(userptr, "glBindImageTexture");
    context->DrawArraysInstancedBaseInstance = (PFNGLDRAWARRAYSINSTANCEDBASEINSTANCEPROC) load(userptr, "glDrawArraysInstancedBaseInstance");
    context->DrawElementsInstancedBaseInstance = (PFNGLDRAWELEMENTSINSTANCEDBASEINSTANCEPROC) load(userptr, "glDrawElementsInstancedBaseInstance");
    context->DrawElementsInstancedBaseVertexBaseInstance = (PFNGLDRAWELEMENTSINSTANCEDBASEVERTEXBASEINSTANCEPROC) load(userptr, "glDrawElementsInstancedBaseVertexBaseInstance");
    context->DrawTransformFeedbackInstanced = (PFNGLDRAWTRANSFORMFEEDBACKINSTANCEDPROC) load(userptr, "glDrawTransformFeedbackInstanced");
    context->DrawTransformFeedbackStreamInstanced = (PFNGLDRAWTRANSFORMFEEDBACKSTREAMINSTANCEDPROC) load(userptr, "glDrawTransformFeedbackStreamInstanced");
    context->GetActiveAtomicCounterBufferiv = (PFNGLGETACTIVEATOMICCOUNTERBUFFERIVPROC) load(userptr, "glGetActiveAtomicCounterBufferiv");
    context->GetInternalformativ = (PFNGLGETINTERNALFORMATIVPROC) load(userptr, "glGetInternalformativ");
    context->MemoryBarrier = (PFNGLMEMORYBARRIERPROC) load(userptr, "glMemoryBarrier");
    context->TexStorage1D = (PFNGLTEXSTORAGE1DPROC) load(userptr, "glTexStorage1D");
    context->TexStorage2D = (PFNGLTEXSTORAGE2DPROC) load(userptr, "glTexStorage2D");
    context->TexStorage3D = (PFNGLTEXSTORAGE3DPROC) load(userptr, "glTexStorage3D");
}
static void glad_gl_load_GL_VERSION_4_3(GladGLContext *context, GLADuserptrloadfunc load, void* userptr) {
    if(!context->VERSION_4_3) return;
    context->BindVertexBuffer = (PFNGLBINDVERTEXBUFFERPROC) load(userptr, "glBindVertexBuffer");
    context->ClearBufferData = (PFNGLCLEARBUFFERDATAPROC) load(userptr, "glClearBufferData");
    context->ClearBufferSubData = (PFNGLCLEARBUFFERSUBDATAPROC) load(userptr, "glClearBufferSubData");
    context->CopyImageSubData = (PFNGLCOPYIMAGESUBDATAPROC) load(userptr, "glCopyImageSubData");
    context->DebugMessageCallback = (PFNGLDEBUGMESSAGECALLBACKPROC) load(userptr, "glDebugMessageCallback");
    context->DebugMessageControl = (PFNGLDEBUGMESSAGECONTROLPROC) load(userptr, "glDebugMessageControl");
    context->DebugMessageInsert = (PFNGLDEBUGMESSAGEINSERTPROC) load(userptr, "glDebugMessageInsert");
    context->DispatchCompute = (PFNGLDISPATCHCOMPUTEPROC) load(userptr, "glDispatchCompute");
    context->DispatchComputeIndirect = (PFNGLDISPATCHCOMPUTEINDIRECTPROC) load(userptr, "glDispatchComputeIndirect");
    context->FramebufferParameteri = (PFNGLFRAMEBUFFERPARAMETERIPROC) load(userptr, "glFramebufferParameteri");
    context->GetDebugMessageLog = (PFNGLGETDEBUGMESSAGELOGPROC) load(userptr, "glGetDebugMessageLog");
    context->GetFramebufferParameteriv = (PFNGLGETFRAMEBUFFERPARAMETERIVPROC) load(userptr, "glGetFramebufferParameteriv");
    context->GetInternalformati64v = (PFNGLGETINTERNALFORMATI64VPROC) load(userptr, "glGetInternalformati64v");
    context->GetObjectLabel = (PFNGLGETOBJECTLABELPROC) load(userptr, "glGetObjectLabel");
    context->GetObjectPtrLabel = (PFNGLGETOBJECTPTRLABELPROC) load(userptr, "glGetObjectPtrLabel");
    context->GetPointerv = (PFNGLGETPOINTERVPROC) load(userptr, "glGetPointerv");
    context->GetProgramInterfaceiv = (PFNGLGETPROGRAMINTERFACEIVPROC) load(userptr, "glGetProgramInterfaceiv");
    context->GetProgramResourceIndex = (PFNGLGETPROGRAMRESOURCEINDEXPROC) load(userptr, "glGetProgramResourceIndex");
    context->GetProgramResourceLocation = (PFNGLGETPROGRAMRESOURCELOCATIONPROC) load(userptr, "glGetProgramResourceLocation");
    context->GetProgramResourceLocationIndex = (PFNGLGETPROGRAMRESOURCELOCATIONINDEXPROC) load(userptr, "glGetProgramResourceLocationIndex");
    context->GetProgramResourceName = (PFNGLGETPROGRAMRESOURCENAMEPROC) load(userptr, "glGetProgramResourceName");
    context->GetProgramResourceiv = (PFNGLGETPROGRAMRESOURCEIVPROC) load(userptr, "glGetProgramResourceiv");
    context->InvalidateBufferData = (PFNGLINVALIDATEBUFFERDATAPROC) load(userptr, "glInvalidateBufferData");
    context->InvalidateBufferSubData = (PFNGLINVALIDATEBUFFERSUBDATAPROC) load(userptr, "glInvalidateBufferSubData");
    context->InvalidateFramebuffer = (PFNGLINVALIDATEFRAMEBUFFERPROC) load(userptr, "glInvalidateFramebuffer");
    context->InvalidateSubFramebuffer = (PFNGLINVALIDATESUBFRAMEBUFFERPROC) load(userptr, "glInvalidateSubFramebuffer");
    context->InvalidateTexImage = (PFNGLINVALIDATETEXIMAGEPROC) load(userptr, "glInvalidateTexImage");
    context->InvalidateTexSubImage = (PFNGLINVALIDATETEXSUBIMAGEPROC) load(userptr, "glInvalidateTexSubImage");
    context->MultiDrawArraysIndirect = (PFNGLMULTIDRAWARRAYSINDIRECTPROC) load(userptr, "glMultiDrawArraysIndirect");
    context->MultiDrawElementsIndirect = (PFNGLMULTIDRAWELEMENTSINDIRECTPROC) load(userptr, "glMultiDrawElementsIndirect");
    context->ObjectLabel = (PFNGLOBJECTLABELPROC) load(userptr, "glObjectLabel");
    context->ObjectPtrLabel = (PFNGLOBJECTPTRLABELPROC) load(userptr, "glObjectPtrLabel");
    context->PopDebugGroup = (PFNGLPOPDEBUGGROUPPROC) load(userptr, "glPopDebugGroup");
    context->PushDebugGroup = (PFNGLPUSHDEBUGGROUPPROC) load(userptr, "glPushDebugGroup");
    context->ShaderStorageBlockBinding = (PFNGLSHADERSTORAGEBLOCKBINDINGPROC) load(userptr, "glShaderStorageBlockBinding");
    context->TexBufferRange = (PFNGLTEXBUFFERRANGEPROC) load(userptr, "glTexBufferRange");
    context->TexStorage2DMultisample = (PFNGLTEXSTORAGE2DMULTISAMPLEPROC) load(userptr, "glTexStorage2DMultisample");
    context->TexStorage3DMultisample = (PFNGLTEXSTORAGE3DMULTISAMPLEPROC) load(userptr, "glTexStorage3DMultisample");
    context->TextureView = (PFNGLTEXTUREVIEWPROC) load(userptr, "glTextureView");
    context->VertexAttribBinding = (PFNGLVERTEXATTRIBBINDINGPROC) load(userptr, "glVertexAttribBinding");
    context->VertexAttribFormat = (PFNGLVERTEXATTRIBFORMATPROC) load(userptr, "glVertexAttribFormat");
    context->VertexAttribIFormat = (PFNGLVERTEXATTRIBIFORMATPROC) load(userptr, "glVertexAttribIFormat");
    context->VertexAttribLFormat = (PFNGLVERTEXATTRIBLFORMATPROC) load(userptr, "glVertexAttribLFormat");
    context->VertexBindingDivisor = (PFNGLVERTEXBINDINGDIVISORPROC) load(userptr, "glVertexBindingDivisor");
}



static void glad_gl_free_extensions(char **exts_i) {
    if (exts_i != NULL) {
        unsigned int index;
        for(index = 0; exts_i[index]; index++) {
            free((void *) (exts_i[index]));
        }
        free((void *)exts_i);
        exts_i = NULL;
    }
}
static int glad_gl_get_extensions(GladGLContext *context, const char **out_exts, char ***out_exts_i) {
#if defined(GL_ES_VERSION_3_0) || defined(GL_VERSION_3_0)
    if (context->GetStringi != NULL && context->GetIntegerv != NULL) {
        unsigned int index = 0;
        unsigned int num_exts_i = 0;
        char **exts_i = NULL;
        context->GetIntegerv(GL_NUM_EXTENSIONS, (int*) &num_exts_i);
        exts_i = (char **) malloc((num_exts_i + 1) * (sizeof *exts_i));
        if (exts_i == NULL) {
            return 0;
        }
        for(index = 0; index < num_exts_i; index++) {
            const char *gl_str_tmp = (const char*) context->GetStringi(GL_EXTENSIONS, index);
            size_t len = strlen(gl_str_tmp) + 1;

            char *local_str = (char*) malloc(len * sizeof(char));
            if(local_str == NULL) {
                exts_i[index] = NULL;
                glad_gl_free_extensions(exts_i);
                return 0;
            }

            memcpy(local_str, gl_str_tmp, len * sizeof(char));
            exts_i[index] = local_str;
        }
        exts_i[index] = NULL;

        *out_exts_i = exts_i;

        return 1;
    }
#else
    GLAD_UNUSED(out_exts_i);
#endif
    if (context->GetString == NULL) {
        return 0;
    }
    *out_exts = (const char *)context->GetString(GL_EXTENSIONS);
    return 1;
}
static int glad_gl_has_extension(const char *exts, char **exts_i, const char *ext) {
    if(exts_i) {
        unsigned int index;
        for(index = 0; exts_i[index]; index++) {
            const char *e = exts_i[index];
            if(strcmp(e, ext) == 0) {
                return 1;
            }
        }
    } else {
        const char *extensions;
        const char *loc;
        const char *terminator;
        extensions = exts;
        if(extensions == NULL || ext == NULL) {
            return 0;
        }
        while(1) {
            loc = strstr(extensions, ext);
            if(loc == NULL) {
                return 0;
            }
            terminator = loc + strlen(ext);
            if((loc == extensions || *(loc - 1) == ' ') &&
                (*terminator == ' ' || *terminator == '\0')) {
                return 1;
            }
            extensions = terminator;
        }
    }
    return 0;
}

static GLADapiproc glad_gl_get_proc_from_userptr(void *userptr, const char* name) {
    return (GLAD_GNUC_EXTENSION (GLADapiproc (*)(const char *name)) userptr)(name);
}

static int glad_gl_find_extensions_gl(GladGLContext *context) {
    const char *exts = NULL;
    char **exts_i = NULL;
    if (!glad_gl_get_extensions(context, &exts, &exts_i)) return 0;

    GLAD_UNUSED(&glad_gl_has_extension);

    glad_gl_free_extensions(exts_i);

    return 1;
}

static int glad_gl_find_core_gl(GladGLContext *context) {
    int i;
    const char* version;
    const char* prefixes[] = {
        "OpenGL ES-CM ",
        "OpenGL ES-CL ",
        "OpenGL ES ",
        "OpenGL SC ",
        NULL
    };
    int major = 0;
    int minor = 0;
    version = (const char*) context->GetString(GL_VERSION);
    if (!version) return 0;
    for (i = 0;  prefixes[i];  i++) {
        const size_t length = strlen(prefixes[i]);
        if (strncmp(version, prefixes[i], length) == 0) {
            version += length;
            break;
        }
    }

    GLAD_IMPL_UTIL_SSCANF(version, "%d.%d", &major, &minor);

    context->VERSION_1_0 = (major == 1 && minor >= 0) || major > 1;
    context->VERSION_1_1 = (major == 1 && minor >= 1) || major > 1;
    context->VERSION_1_2 = (major == 1 && minor >= 2) || major > 1;
    context->VERSION_1_3 = (major == 1 && minor >= 3) || major > 1;
    context->VERSION_1_4 = (major == 1 && minor >= 4) || major > 1;
    context->VERSION_1_5 = (major == 1 && minor >= 5) || major > 1;
    context->VERSION_2_0 = (major == 2 && minor >= 0) || major > 2;
    context->VERSION_2_1 = (major == 2 && minor >= 1) || major > 2;
    context->VERSION_3_0 = (major == 3 && minor >= 0) || major > 3;
    context->VERSION_3_1 = (major == 3 && minor >= 1) || major > 3;
    context->VERSION_3_2 = (major == 3 && minor >= 2) || major > 3;
    context->VERSION_3_3 = (major == 3 && minor >= 3) || major > 3;
    context->VERSION_4_0 = (major == 4 && minor >= 0) || major > 4;
    context->VERSION_4_1 = (major == 4 && minor >= 1) || major > 4;
    context->VERSION_4_2 = (major == 4 && minor >= 2) || major > 4;
    context->VERSION_4_3 = (major == 4 && minor >= 3) || major > 4;

    return GLAD_MAKE_VERSION(major, minor);
}

int gladLoadGLContextUserPtr(GladGLContext *context, GLADuserptrloadfunc load, void *userptr) {
    int version;

    context->GetString = (PFNGLGETSTRINGPROC) load(userptr, "glGetString");
    if(context->GetString == NULL) return 0;
    version = glad_gl_find_core_gl(context);

    glad_gl_load_GL_VERSION_1_0(context, load, userptr);
    glad_gl_load_GL_VERSION_1_1(context, load, userptr);
    glad_gl_load_GL_VERSION_1_2(context, load, userptr);
    glad_gl_load_GL_VERSION_1_3(context, load, userptr);
    glad_gl_load_GL_VERSION_1_4(context, load, userptr);
    glad_gl_load_GL_VERSION_1_5(context, load, userptr);
    glad_gl_load_GL_VERSION_2_0(context, load, userptr);
    glad_gl_load_GL_VERSION_2_1(context, load, userptr);
    glad_gl_load_GL_VERSION_3_0(context, load, userptr);
    glad_gl_load_GL_VERSION_3_1(context, load, userptr);
    glad_gl_load_GL_VERSION_3_2(context, load, userptr);
    glad_gl_load_GL_VERSION_3_3(context, load, userptr);
    glad_gl_load_GL_VERSION_4_0(context, load, userptr);
    glad_gl_load_GL_VERSION_4_1(context, load, userptr);
    glad_gl_load_GL_VERSION_4_2(context, load, userptr);
    glad_gl_load_GL_VERSION_4_3(context, load, userptr);

    if (!glad_gl_find_extensions_gl(context)) return 0;



    return version;
}


int gladLoadGLContext(GladGLContext *context, GLADloadfunc load) {
    return gladLoadGLContextUserPtr(context, glad_gl_get_proc_from_userptr, GLAD_GNUC_EXTENSION (void*) load);
}



 

#ifdef GLAD_GL

#ifndef GLAD_LOADER_LIBRARY_C_
#define GLAD_LOADER_LIBRARY_C_

#include <stddef.h>
#include <stdlib.h>

#if GLAD_PLATFORM_WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif


static void* glad_get_dlopen_handle(const char *lib_names[], int length) {
    void *handle = NULL;
    int i;

    for (i = 0; i < length; ++i) {
#if GLAD_PLATFORM_WIN32
  #if GLAD_PLATFORM_UWP
        size_t buffer_size = (strlen(lib_names[i]) + 1) * sizeof(WCHAR);
        LPWSTR buffer = (LPWSTR) malloc(buffer_size);
        if (buffer != NULL) {
            int ret = MultiByteToWideChar(CP_ACP, 0, lib_names[i], -1, buffer, buffer_size);
            if (ret != 0) {
                handle = (void*) LoadPackagedLibrary(buffer, 0);
            }
            free((void*) buffer);
        }
  #else
        handle = (void*) LoadLibraryA(lib_names[i]);
  #endif
#else
        handle = dlopen(lib_names[i], RTLD_LAZY | RTLD_LOCAL);
#endif
        if (handle != NULL) {
            return handle;
        }
    }

    return NULL;
}

static void glad_close_dlopen_handle(void* handle) {
    if (handle != NULL) {
#if GLAD_PLATFORM_WIN32
        FreeLibrary((HMODULE) handle);
#else
        dlclose(handle);
#endif
    }
}

static GLADapiproc glad_dlsym_handle(void* handle, const char *name) {
    if (handle == NULL) {
        return NULL;
    }

#if GLAD_PLATFORM_WIN32
    return (GLADapiproc) GetProcAddress((HMODULE) handle, name);
#else
    return GLAD_GNUC_EXTENSION (GLADapiproc) dlsym(handle, name);
#endif
}

#endif /* GLAD_LOADER_LIBRARY_C_ */

typedef void* (GLAD_API_PTR *GLADglprocaddrfunc)(const char*);
struct _glad_gl_userptr {
    void *handle;
    GLADglprocaddrfunc gl_get_proc_address_ptr;
};

static GLADapiproc glad_gl_get_proc(void *vuserptr, const char *name) {
    struct _glad_gl_userptr userptr = *(struct _glad_gl_userptr*) vuserptr;
    GLADapiproc result = NULL;

    if(userptr.gl_get_proc_address_ptr != NULL) {
        result = GLAD_GNUC_EXTENSION (GLADapiproc) userptr.gl_get_proc_address_ptr(name);
    }
    if(result == NULL) {
        result = glad_dlsym_handle(userptr.handle, name);
    }

    return result;
}


static void* glad_gl_dlopen_handle(GladGLContext *context) {
#if GLAD_PLATFORM_APPLE
    static const char *NAMES[] = {
        "../Frameworks/OpenGL.framework/OpenGL",
        "/Library/Frameworks/OpenGL.framework/OpenGL",
        "/System/Library/Frameworks/OpenGL.framework/OpenGL",
        "/System/Library/Frameworks/OpenGL.framework/Versions/Current/OpenGL"
    };
#elif GLAD_PLATFORM_WIN32
    static const char *NAMES[] = {"opengl32.dll"};
#else
    static const char *NAMES[] = {
  #if defined(__CYGWIN__)
        "libGL-1.so",
  #endif
        "libGL.so.1",
        "libGL.so"
    };
#endif

    if (context->glad_loader_handle == NULL) {
        context->glad_loader_handle = glad_get_dlopen_handle(NAMES, sizeof(NAMES) / sizeof(NAMES[0]));
    }

    return context->glad_loader_handle;
}

static struct _glad_gl_userptr glad_gl_build_userptr(void *handle) {
    struct _glad_gl_userptr userptr;

    userptr.handle = handle;
#if GLAD_PLATFORM_APPLE || defined(__HAIKU__)
    userptr.gl_get_proc_address_ptr = NULL;
#elif GLAD_PLATFORM_WIN32
    userptr.gl_get_proc_address_ptr =
        (GLADglprocaddrfunc) glad_dlsym_handle(handle, "wglGetProcAddress");
#else
    userptr.gl_get_proc_address_ptr =
        (GLADglprocaddrfunc) glad_dlsym_handle(handle, "glXGetProcAddressARB");
#endif

    return userptr;
}

int gladLoaderLoadGLContext(GladGLContext *context) {
    int version = 0;
    void *handle;
    int did_load = 0;
    struct _glad_gl_userptr userptr;

    did_load = context->glad_loader_handle == NULL;
    handle = glad_gl_dlopen_handle(context);
    if (handle) {
        userptr = glad_gl_build_userptr(handle);

        version = gladLoadGLContextUserPtr(context,glad_gl_get_proc, &userptr);

        if (did_load) {
            gladLoaderUnloadGLContext(context);
        }
    }

    return version;
}



void gladLoaderUnloadGLContext(GladGLContext *context) {
    if (context->glad_loader_handle != NULL) {
        glad_close_dlopen_handle(context->glad_loader_handle);
        context->glad_loader_handle = NULL;
    }
}

#endif /* GLAD_GL */

#ifdef __cplusplus
}
#endif
