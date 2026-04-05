shader_type sky;

// ── Utility ───────────────────────────────────────────────────────────────────

float hash3(vec3 p) {
	p  = fract(p * vec3(443.897, 397.297, 491.187));
	p += dot(p.zxy, p.yxz + 19.19);
	return fract(p.x * p.y * p.z);
}

// 3D value noise — no UV, no stretching
float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash3(i + vec3(0,0,0)), hash3(i + vec3(1,0,0)), f.x),
		    mix(hash3(i + vec3(0,1,0)), hash3(i + vec3(1,1,0)), f.x), f.y),
		mix(mix(hash3(i + vec3(0,0,1)), hash3(i + vec3(1,0,1)), f.x),
		    mix(hash3(i + vec3(0,1,1)), hash3(i + vec3(1,1,1)), f.x), f.y),
		f.z);
}

// Single star layer — operates in 3D so uniform across the whole sphere
float star_layer(vec3 dir, float scale, float threshold, float size) {
	vec3 p    = dir * scale;
	vec3 cell = floor(p);
	vec3 fr   = fract(p);
	float h   = hash3(cell);
	if (h < threshold) return 0.0;
	vec3 sp   = vec3(hash3(cell + 1.1), hash3(cell + 2.2), hash3(cell + 3.3));
	float d   = length(fr - sp);
	return smoothstep(size, 0.0, d) * ((h - threshold) / (1.0 - threshold));
}

// ── Sky ───────────────────────────────────────────────────────────────────────

void sky() {
	vec3 dir = EYEDIR;

	// ── Background: near-black space with very faint nebula ───────────────────
	float n1 = vnoise(dir * 2.2) * vnoise(dir * 4.1 + 1.3);
	float n2 = vnoise(dir * 3.5 + vec3(2.1, 0.5, 1.3));
	vec3 bg  = vec3(0.0);
	bg += vec3(0.010, 0.006, 0.022) * n1 * 2.0;   // deep purple cloud
	bg += vec3(0.004, 0.012, 0.022) * n2 * 1.2;   // teal-blue cloud

	// ── Milky Way: faint horizontal band ─────────────────────────────────────
	float band   = exp(-pow(dir.y * 4.0, 2.0));
	float band_n = vnoise(dir * 6.0) * vnoise(dir * 11.0 + 0.9);
	bg += vec3(0.018, 0.012, 0.030) * band * band_n * 2.5;

	// ── Stars: 4 depth layers ─────────────────────────────────────────────────
	float s = 0.0;
	s += star_layer(dir,  55.0, 0.965, 0.090) * 3.0;  // rare, large, very bright
	s += star_layer(dir, 110.0, 0.945, 0.060) * 1.8;  // medium
	s += star_layer(dir, 210.0, 0.925, 0.042) * 1.1;  // dense small
	s += star_layer(dir, 380.0, 0.905, 0.030) * 0.6;  // tiny background dust

	// ── Star colour ───────────────────────────────────────────────────────────
	float th = hash3(dir * 73.1);
	vec3 star_col;
	if (th < 0.35)
		star_col = mix(vec3(0.75, 0.85, 1.00), vec3(1.00, 1.00, 1.00), th / 0.35);
	else if (th < 0.75)
		star_col = vec3(1.00, 1.00, 0.97);
	else
		star_col = mix(vec3(1.00, 0.95, 0.80), vec3(1.00, 0.75, 0.50), (th - 0.75) / 0.25);

	// ── Composite ─────────────────────────────────────────────────────────────
	COLOR = clamp(bg + star_col * s, vec3(0.0), vec3(2.5));
}
