import React from 'react';

// 動画で使う線のアイコン（自作。24 × 24 の枠で描く）
const paths: Record<string, React.ReactNode> = {
	note: (
		<>
			<rect x="4" y="3" width="16" height="18" rx="3" />
			<path d="M8 8h8M8 12h8M8 16h5" />
		</>
	),
	doc: (
		<>
			<path d="M7 3h7l5 5v12a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z" />
			<path d="M14 3v5h5M9 13h6M9 17h4" />
		</>
	),
	globe: (
		<>
			<circle cx="12" cy="12" r="9" />
			<path d="M3 12h18M12 3c3 3.5 3 14.5 0 18M12 3c-3 3.5-3 14.5 0 18" />
		</>
	),
	image: (
		<>
			<rect x="3" y="4" width="18" height="16" rx="3" />
			<circle cx="9" cy="10" r="2" />
			<path d="M21 16l-5-5-9 9" />
		</>
	),
	palette: (
		<>
			<path d="M12 3a9 9 0 1 0 0 18c1.5 0 2-1 2-2s-1-1.5-1-2.5 1-1.5 2-1.5h2a4 4 0 0 0 4-4c0-4.4-4-8-9-8z" />
			<circle cx="7.5" cy="11" r="1.2" />
			<circle cx="10" cy="7" r="1.2" />
			<circle cx="15" cy="7.5" r="1.2" />
		</>
	),
	folder: <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />,
	film: (
		<>
			<rect x="3" y="5" width="18" height="14" rx="2" />
			<path d="M7 5v14M17 5v14M3 9h4M3 15h4M17 9h4M17 15h4" />
		</>
	),
	clapper: (
		<>
			<path d="M4 10h16v9a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1z" />
			<path d="M4 10l1-5 15 2.5-.6 2.5M9 5.8l2 4M14 6.6l2 3.4" />
		</>
	),
	search: (
		<>
			<circle cx="11" cy="11" r="7" />
			<path d="M20 20l-4-4" />
		</>
	),
	pin: <path d="M9 3h6l-1 6 4 4H6l4-4zM12 13v8" />,
	sparkles: (
		<>
			<path d="M11 3l1.8 5.2L18 10l-5.2 1.8L11 17l-1.8-5.2L4 10l5.2-1.8z" />
			<path d="M19 14l.7 2.3L22 17l-2.3.7L19 20l-.7-2.3L16 17l2.3-.7z" />
		</>
	),
	wand: <path d="M4 20 14 10M15 3v2.5M15 12.5V15M9.5 9H12M18 9h2.5M18 6l1.8-1.8M11.8 12.2 10 14" />,
	stack: (
		<>
			<rect x="4" y="12" width="16" height="8" rx="2" />
			<path d="M6 8.5h12M8.5 5h7" />
		</>
	),
	clock: (
		<>
			<circle cx="12" cy="12" r="9" />
			<path d="M12 7v5l3 2" />
		</>
	),
	tray: <path d="M4 13h4l1 3h6l1-3h4M4 13l2-8h12l2 8v6H4z" />,
	cursor: <path d="M6 3l13 7-6 1.8L10.5 18z" />,
	keyboard: (
		<>
			<rect x="2.5" y="6" width="19" height="12" rx="2" />
			<path d="M6.5 10h1M10.5 10h1M14.5 10h1M7 14h10" />
		</>
	),
	shield: <path d="M12 3l8 3v6c0 4.5-3.4 8.2-8 9-4.6-.8-8-4.5-8-9V6zM8.5 12l2.5 2.5 4.5-5" />,
};

export type IconName = keyof typeof paths;

export const Icon: React.FC<{name: IconName; size?: number; color?: string; strokeWidth?: number; style?: React.CSSProperties}> = ({
	name,
	size = 24,
	color = 'currentColor',
	strokeWidth = 2,
	style,
}) => (
	<svg
		width={size}
		height={size}
		viewBox="0 0 24 24"
		fill="none"
		stroke={color}
		strokeWidth={strokeWidth}
		strokeLinecap="round"
		strokeLinejoin="round"
		style={{flexShrink: 0, ...style}}
	>
		{paths[name]}
	</svg>
);

/** 種類ごとの色（アプリのアイコンの地） */
const tileColors: Partial<Record<IconName, [string, string]>> = {
	note: ['#ffcf4a', '#ff9f0a'],
	doc: ['#ff7a6b', '#e5484d'],
	globe: ['#5ac8fa', '#0a84ff'],
	image: ['#ff8fb1', '#e6457a'],
	palette: ['#c58cff', '#8e5bf2'],
	folder: ['#7fd3ff', '#2f9bff'],
	clapper: ['#9b7bff', '#5b3cc4'],
	film: ['#9b7bff', '#5b3cc4'],
	search: ['#7ad7c4', '#21a68d'],
	pin: ['#5aa9ff', '#0a6cff'],
	wand: ['#ffb35c', '#ff6b2c'],
	stack: ['#6ee7a8', '#22b070'],
	tray: ['#8fa8ff', '#4a63e0'],
	cursor: ['#ffd36b', '#f0a20a'],
	shield: ['#9be7a4', '#2fb34f'],
};

/** 色の付いた角丸の板に白いアイコン（アプリのアイコンの代わり） */
export const IconTile: React.FC<{name: IconName; size?: number; style?: React.CSSProperties}> = ({name, size = 26, style}) => {
	const [from, to] = tileColors[name] ?? ['#a0a4b8', '#6e7387'];
	return (
		<div
			style={{
				width: size,
				height: size,
				borderRadius: size * 0.26,
				background: `linear-gradient(160deg, ${from}, ${to})`,
				boxShadow: `0 ${size * 0.06}px ${size * 0.18}px rgba(0,0,0,0.25), inset 0 1px 0 rgba(255,255,255,0.35)`,
				display: 'flex',
				alignItems: 'center',
				justifyContent: 'center',
				flexShrink: 0,
				...style,
			}}
		>
			<Icon name={name} size={size * 0.6} color="white" strokeWidth={2.2} />
		</div>
	);
};
