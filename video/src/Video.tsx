import React from 'react';
import {AbsoluteFill, Audio, interpolate, Sequence, staticFile} from 'remotion';
import {DURATIONS, FinalCutScene, Intro, Open, Outro, PasteScene, PinboardScene, SearchScene, StackScene, TransformScene} from './scenes';
import {Space} from './three/Space';
import {clamp, colors} from './theme';

const order: [keyof typeof DURATIONS, React.FC][] = [
	['intro', Intro],
	['open', Open],
	['paste', PasteScene],
	['search', SearchScene],
	['pinboard', PinboardScene],
	['transform', TransformScene],
	['fcp', FinalCutScene],
	['stack', StackScene],
	['outro', Outro],
];

export const TOTAL = order.reduce((sum, [key]) => sum + DURATIONS[key], 0);

export const CopipeTutorial: React.FC = () => {
	let start = 0;
	const sequences = order.map(([key, Scene]) => {
		const from = start;
		start += DURATIONS[key];
		return (
			<Sequence key={key} from={from} durationInFrames={DURATIONS[key]} name={key}>
				<Scene />
			</Sequence>
		);
	});
	const middleFrom = DURATIONS.intro;
	const middleLength = TOTAL - DURATIONS.intro - DURATIONS.outro;
	return (
		<AbsoluteFill style={{background: `linear-gradient(160deg, ${colors.bgTop}, ${colors.bgBottom})`}}>
			{/* 使い方の場面の後ろで、カードがゆっくり漂う宇宙（デスクトップの壁紙の代わり） */}
			<Sequence from={middleFrom} durationInFrames={middleLength} name="background">
				<Space mode="background" />
				{/* 上の説明が読みやすいように、上のほうを少し暗くする */}
				<AbsoluteFill style={{background: 'linear-gradient(rgba(6,8,26,0.8), rgba(6,8,26,0.35) 30%, transparent 55%)'}} />
			</Sequence>
			{sequences}
			<Audio src={staticFile('bgm.wav')} volume={(f) => interpolate(f, [TOTAL - 30, TOTAL], [0.85, 0], clamp)} />
		</AbsoluteFill>
	);
};
