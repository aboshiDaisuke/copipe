import type {ExtrapolateType} from 'remotion';

/** interpolate は基本はみ出さない */
export const clamp = {
	extrapolateLeft: 'clamp' as ExtrapolateType,
	extrapolateRight: 'clamp' as ExtrapolateType,
};

export const font = '"Hiragino Sans", "Hiragino Kaku Gothic ProN", "Noto Sans JP", sans-serif';

/** Copipe のピンボードの色 */
export const palette = ['#F0544D', '#FF9F0A', '#FFD60A', '#30D158', '#40C8E0', '#0A84FF', '#BF5AF2', '#8E8E93'];

export const colors = {
	ink: '#1d1d1f',
	sub: '#6e6e73',
	accent: '#0A84FF',
	bgTop: '#0d1230',
	bgBottom: '#2a1d55',
};

export const FPS = 30;
