#include <metal_stdlib>
using namespace metal;

struct V2F {
	float4 pos [[position]];
	half3 color;
};

struct alignas(16) Config {
	float invHalfWindowSize;
	float heightAdjust;
	uint startPos;
	uint idxWrap;
	uint posOff;
	uint posWidth;
};

vertex V2F vs(uint vid [[vertex_id]], device const float* data [[buffer(0)]], constant Config& cfg) {
	uint pos = vid >> 2;
	uint idx = (cfg.startPos - pos) & cfg.idxWrap;
	uint outpos = pos + cfg.posOff;
	if (outpos > cfg.posWidth)
		outpos -= cfg.posWidth;
	bool isLeft = vid & 1;
	bool isBottom = vid & 2;
	float ns = data[idx];
	float height = saturate(ns * cfg.heightAdjust);
	half color = saturate(half(height) * 2.h) * 2.h;
	float width = cfg.invHalfWindowSize;
	V2F out;
	out.pos = float4(1 - (outpos + isLeft) * width, isBottom ? -height : height, 0, 1);
	out.color = half3(saturate(color), saturate(2.h - color), 0);
	return out;
}

fragment half4 fs(V2F in [[stage_in]]) {
	return half4(in.color, 1);
}
