import React from 'react';
import {AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {Icon, IconName, IconTile} from './icons';
import {clamp, colors, font} from './theme';

// ここに出すカードの中身はすべて見本（架空の文章・名前）

export type CardData = {
	id: string;
	kind: 'text' | 'link' | 'image' | 'color' | 'file' | 'fcp';
	title: string;
	time: string;
	icon: IconName;
	body?: string;
	footer?: string;
	/** ピンボードの色 */
	board?: string;
	/** 画像・リンクの絵（CSS の背景） */
	art?: string;
	fcp?: {names: string[]; effects: string[]; duration: string};
};

export const CARD_W = 240;
export const CARD_H = 256;

const AppIcon: React.FC<{icon: IconName; size?: number}> = ({icon, size = 26}) => <IconTile name={icon} size={size} />;

/** Copipe のカード（Paste 7 と同じ形） */
export const Card: React.FC<{data: CardData; selected?: boolean; style?: React.CSSProperties}> = ({data, selected, style}) => {
	const onMedia = data.kind === 'image' || (data.kind === 'link' && data.art);
	const header = (
		<div
			style={{
				display: 'flex',
				alignItems: 'center',
				gap: 6,
				height: 44,
				padding: '0 14px',
				color: onMedia ? 'white' : colors.ink,
				textShadow: onMedia ? '0 1px 3px rgba(0,0,0,0.45)' : undefined,
				background: onMedia ? 'linear-gradient(rgba(0,0,0,0.45), transparent)' : undefined,
				position: onMedia ? 'absolute' : 'relative',
				left: 0,
				right: 0,
				top: 0,
				zIndex: 1,
			}}
		>
			{data.board ? <div style={{width: 9, height: 9, borderRadius: 5, background: data.board}} /> : null}
			<span style={{fontSize: 14, fontWeight: 700, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', minWidth: 0}}>{data.title}</span>
			<span style={{fontSize: 14, opacity: 0.7, whiteSpace: 'nowrap'}}>{data.time}</span>
			<div style={{flex: 1}} />
			<AppIcon icon={data.icon} />
		</div>
	);
	const footer = data.footer ? (
		<div style={{position: 'absolute', left: 14, bottom: 12, fontSize: 12, color: onMedia ? 'white' : colors.sub}}>{data.footer}</div>
	) : null;

	let body: React.ReactNode = null;
	if (data.kind === 'text') {
		body = <div style={{padding: '2px 14px', fontSize: 15, lineHeight: 1.6, color: colors.ink, whiteSpace: 'pre-wrap'}}>{data.body}</div>;
	} else if (data.kind === 'file') {
		body = (
			<div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12, paddingTop: 34}}>
				<IconTile name="doc" size={84} />
				<div style={{fontSize: 15, fontWeight: 600, color: colors.ink}}>{data.body}</div>
			</div>
		);
	} else if (data.kind === 'color') {
		body = (
			<div style={{position: 'absolute', inset: 0, background: data.body, display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'white', fontSize: 24, fontWeight: 600, fontFamily: 'Menlo, monospace'}}>
				{data.body}
			</div>
		);
	} else if (data.kind === 'image') {
		body = <div style={{position: 'absolute', inset: 0, background: data.art}} />;
	} else if (data.kind === 'link') {
		body = (
			<div style={{position: 'absolute', inset: 0}}>
				<div style={{height: 150, background: data.art}} />
				<div style={{padding: '10px 14px', fontSize: 15, fontWeight: 700, color: colors.ink, lineHeight: 1.35}}>{data.body}</div>
			</div>
		);
	} else if (data.kind === 'fcp' && data.fcp) {
		body = (
			<div style={{padding: '4px 14px', display: 'flex', flexDirection: 'column', gap: 6}}>
				{data.fcp.names.map((name) => (
					<div key={name} style={{display: 'flex', alignItems: 'center', gap: 6, fontSize: 14, fontWeight: 600, color: colors.ink, whiteSpace: 'nowrap', overflow: 'hidden'}}>
						<Icon name="film" size={16} color={colors.sub} />
						{name}
					</div>
				))}
				<div style={{display: 'flex', alignItems: 'center', gap: 6, fontSize: 13, color: colors.sub}}>
					<Icon name="sparkles" size={15} />
					{data.fcp.effects.join('・')}
				</div>
			</div>
		);
	}

	return (
		<div
			style={{
				position: 'relative',
				width: CARD_W,
				height: CARD_H,
				flexShrink: 0,
				borderRadius: 18,
				background: data.board ? `color-mix(in srgb, ${data.board} 12%, white)` : 'white',
				boxShadow: selected
					? `0 0 0 4px white, 0 0 0 8px ${colors.accent}, 0 8px 20px rgba(0,0,0,0.25)`
					: '0 0 0 1px rgba(0,0,0,0.06), 0 6px 16px rgba(0,0,0,0.22)',
				overflow: 'hidden',
				fontFamily: font,
				...style,
			}}
		>
			{body && (data.kind === 'color' || data.kind === 'image' || data.kind === 'link') ? body : null}
			{data.kind === 'color' ? null : header}
			{data.kind === 'text' || data.kind === 'file' || data.kind === 'fcp' ? body : null}
			{footer}
		</div>
	);
};

export type Tab = {name: string; color: string};

/** 画面の下に出る履歴パネル（検索欄・タブ・カード） */
export const Panel: React.FC<{
	cards: CardData[];
	selected?: number;
	/** カードごとの見た目（消えていく・浮くなど） */
	cardStyle?: (index: number) => React.CSSProperties;
	search?: string;
	tabs: Tab[];
	activeTab: number;
	tabStyle?: (index: number) => React.CSSProperties;
	offsetY?: number;
	children?: React.ReactNode;
}> = ({cards, selected, cardStyle, search = '', tabs, activeTab, tabStyle, offsetY = 0, children}) => {
	return (
		<div
			style={{
				position: 'absolute',
				left: 0,
				right: 0,
				bottom: 0,
				height: 352,
				transform: `translateY(${offsetY}px)`,
				background: 'rgba(236, 237, 242, 0.88)',
				backdropFilter: 'blur(30px)',
				borderTopLeftRadius: 16,
				borderTopRightRadius: 16,
				boxShadow: '0 -10px 40px rgba(0,0,0,0.35)',
				fontFamily: font,
			}}
		>
			<div style={{position: 'relative', height: 54, display: 'flex', alignItems: 'center', padding: '0 20px'}}>
				<div style={{width: 220, height: 28, borderRadius: 14, background: search ? 'rgba(0,0,0,0.1)' : 'rgba(0,0,0,0.05)', display: 'flex', alignItems: 'center', gap: 6, padding: '0 10px', fontSize: 14, color: search ? colors.ink : '#9a9aa0'}}>
					<Icon name="search" size={15} color={colors.sub} />
					<span>{search || '検索'}</span>
					{search ? <span style={{width: 2, height: 16, background: colors.accent}} /> : null}
				</div>
				<div style={{position: 'absolute', left: 0, right: 0, display: 'flex', justifyContent: 'center', gap: 4, pointerEvents: 'none'}}>
					{tabs.map((tab, i) => (
						<div
							key={tab.name}
							style={{
								display: 'flex',
								alignItems: 'center',
								gap: 6,
								height: 26,
								padding: '0 12px',
								borderRadius: 13,
								fontSize: 13,
								fontWeight: i === activeTab ? 700 : 400,
								color: colors.ink,
								background: i === activeTab ? 'rgba(0,0,0,0.12)' : 'transparent',
								...tabStyle?.(i),
							}}
						>
							<div style={{width: 8, height: 8, borderRadius: 4, background: tab.color}} />
							{tab.name}
						</div>
					))}
					<div style={{fontSize: 16, color: colors.sub, padding: '0 8px'}}>＋</div>
				</div>
			</div>
			<div style={{display: 'flex', gap: 16, padding: '8px 20px'}}>
				{cards.map((card, i) => (
					<Card key={card.id} data={card} selected={i === selected} style={cardStyle?.(i)} />
				))}
			</div>
			{children}
		</div>
	);
};

/** キーを押す様子。"⌘|command" のように書くと、記号の下に名前を小さく出す。pressAt を並べると何度も押す */
export const Keys: React.FC<{keys: string[]; appearAt: number; pressAt: number | number[]; hideAt?: number; top?: number}> = ({
	keys,
	appearAt,
	pressAt,
	hideAt = 9999,
	top = 330,
}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const show = spring({frame: frame - appearAt, fps, config: {damping: 14}});
	const hide = interpolate(frame, [hideAt, hideAt + 8], [1, 0], clamp);
	const presses = Array.isArray(pressAt) ? pressAt : [pressAt];
	const press = Math.max(...presses.map((at) => interpolate(frame, [at - 3, at, at + 6], [0, 1, 0], clamp)));
	if (frame < appearAt || frame > hideAt + 8) return null;
	return (
		<div
			style={{
				position: 'absolute',
				top,
				left: 0,
				right: 0,
				display: 'flex',
				justifyContent: 'center',
				opacity: show * hide,
				transform: `scale(${0.8 + show * 0.2})`,
			}}
		>
			<div style={{display: 'flex', gap: 16, padding: '22px 30px', borderRadius: 30, background: 'rgba(10,12,30,0.55)', backdropFilter: 'blur(12px)'}}>
				{keys.map((key, i) => {
					const [glyph, label] = key.split('|');
					return (
						<React.Fragment key={key + i}>
							{i > 0 ? <div style={{color: 'white', fontSize: 40, alignSelf: 'center', opacity: 0.7}}>+</div> : null}
							<div
								style={{
									minWidth: 104,
									height: 104,
									padding: '0 22px',
									borderRadius: 20,
									background: 'linear-gradient(#ffffff, #dfe2ea)',
									boxShadow: `0 ${8 - press * 6}px 0 #9aa0b4, 0 ${14 - press * 8}px 24px rgba(0,0,0,0.35)`,
									transform: `translateY(${press * 6}px)`,
									display: 'flex',
									flexDirection: 'column',
									alignItems: 'center',
									justifyContent: 'center',
									fontFamily: font,
									color: colors.ink,
								}}
							>
								<div style={{fontSize: glyph.length > 2 ? 30 : 46, fontWeight: 600, lineHeight: 1.1}}>{glyph}</div>
								{label ? <div style={{fontSize: 17, color: colors.sub, marginTop: 2}}>{label}</div> : null}
							</div>
						</React.Fragment>
					);
				})}
			</div>
		</div>
	);
};

/** 左上の説明（番号・見出し・ひとこと） */
export const Caption: React.FC<{step: number; title: string; sub: string; icon: IconName}> = ({step, title, sub, icon}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const p = spring({frame: frame - 6, fps, config: {damping: 16}});
	return (
		<div style={{position: 'absolute', left: 90, top: 70, fontFamily: font, color: 'white', opacity: p, transform: `translateX(${(1 - p) * -40}px)`}}>
			<div style={{display: 'flex', alignItems: 'center', gap: 22}}>
				<IconTile name={icon} size={86} style={{transform: `rotate(${(1 - p) * -12}deg)`}} />
				<div>
					<div style={{fontSize: 22, fontWeight: 800, letterSpacing: 4, color: '#9fc6ff'}}>STEP {step}</div>
					<div style={{fontSize: 58, fontWeight: 800, letterSpacing: 1, lineHeight: 1.15, textShadow: '0 4px 18px rgba(0,0,0,0.45)'}}>{title}</div>
				</div>
			</div>
			<div style={{marginTop: 16, marginLeft: 108, fontSize: 30, fontWeight: 500, opacity: 0.92, maxWidth: 1700, lineHeight: 1.5, textShadow: '0 2px 10px rgba(0,0,0,0.5)'}}>{sub}</div>
		</div>
	);
};

/** 貼り付け先の書類の窓（メモ帳のような見本） */
export const DocWindow: React.FC<{title: string; lines: React.ReactNode[]; style?: React.CSSProperties}> = ({title, lines, style}) => (
	<div
		style={{
			position: 'absolute',
			left: 960 - 470,
			top: 290,
			width: 940,
			height: 330,
			borderRadius: 14,
			background: '#ffffff',
			boxShadow: '0 20px 60px rgba(0,0,0,0.45)',
			fontFamily: font,
			overflow: 'hidden',
			...style,
		}}
	>
		<div style={{height: 40, display: 'flex', alignItems: 'center', gap: 8, padding: '0 16px', background: '#f2f2f5', borderBottom: '1px solid #e2e2e8'}}>
			{['#ff5f57', '#febc2e', '#28c840'].map((c) => (
				<div key={c} style={{width: 13, height: 13, borderRadius: 7, background: c}} />
			))}
			<div style={{flex: 1, textAlign: 'center', fontSize: 16, color: colors.sub, marginRight: 60}}>{title}</div>
		</div>
		<div style={{padding: '22px 30px', fontSize: 28, lineHeight: 1.65, color: colors.ink}}>
			{lines.map((line, i) => (
				<div key={i}>{line}</div>
			))}
		</div>
	</div>
);

/** シーンの出入りをふわっとさせる */
export const SceneFade: React.FC<{duration: number; children: React.ReactNode}> = ({duration, children}) => {
	const frame = useCurrentFrame();
	const opacity = interpolate(frame, [0, 12, duration - 12, duration], [0, 1, 1, 0], clamp);
	return <AbsoluteFill style={{opacity}}>{children}</AbsoluteFill>;
};

/** パネルを下から出す・しまうときの位置 */
export const usePanelOffset = (inAt: number, outAt = 99999) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const up = spring({frame: frame - inAt, fps, config: {damping: 18}});
	const down = spring({frame: frame - outAt, fps, config: {damping: 18}});
	return (1 - up) * 400 + down * 400;
};
