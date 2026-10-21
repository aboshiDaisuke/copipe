import React from 'react';
import {Composition} from 'remotion';
import {FPS} from './theme';
import {CopipeTutorial, TOTAL} from './Video';

export const Root: React.FC = () => (
	<Composition id="CopipeTutorial" component={CopipeTutorial} durationInFrames={TOTAL} fps={FPS} width={1920} height={1080} />
);
