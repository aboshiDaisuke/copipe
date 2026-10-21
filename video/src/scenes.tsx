import React from 'react';
import {AbsoluteFill, Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {fcpCard, historyCards, pinnedCards, tabs} from './data';
import {Icon, IconName, IconTile} from './icons';
import {Space} from './three/Space';
import {clamp, colors, font, palette} from './theme';
import {Caption, Card, CARD_H, CARD_W, DocWindow, Keys, Panel, SceneFade, usePanelOffset} from './ui';

/** パネルは実物の 1.3 倍で見せる */
const S = 1.3;
const PANEL_TOP = 1080 - 352 * S;

const ScaledPanel: React.FC<{children: React.ReactNode}> = ({children}) => (
	<div style={{position: 'absolute', left: 0, bottom: 0, width: 1920 / S, height: 352, transform: `scale(${S})`, transformOrigin: 'bottom left'}}>
		{children}
	</div>
);

/** パネルの index 番目のカードの、画面上の左上 */
const cardOrigin = (index: number) => ({x: (20 + index * (CARD_W + 16)) * S, y: PANEL_TOP + (54 + 8) * S});

// どの場面も 2 秒（BGM の 1 小節）の倍数。場面の変わり目が BGM の区切りにそろう
export const DURATIONS = {intro: 120, open: 300, paste: 300, search: 240, pinboard: 300, transform: 300, fcp: 240, stack: 300, outro: 240};

// MARK: - はじまり

export const Intro: React.FC = () => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const icon = spring({frame: frame - 12, fps, config: {damping: 12, mass: 0.8}});
	const title = spring({frame: frame - 35, fps, config: {damping: 14}});
	const sub = spring({frame: frame - 55, fps, config: {damping: 16}});
	const out = interpolate(frame, [104, 120], [1, 0], clamp);
	const glow = 0.35 + Math.sin(frame / 8) * 0.1;
	return (
		<AbsoluteFill style={{opacity: out}}>
			<Space mode="intro" />
			{/* 文字の後ろだけ暗くして読みやすく */}
			<AbsoluteFill style={{background: `radial-gradient(ellipse 900px 520px at 50% 50%, rgba(8,10,30,${0.75 * title}), transparent)`}} />
			<AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', fontFamily: font, color: 'white'}}>
				<div style={{perspective: 900, marginBottom: 6}}>
					<Img
						src={staticFile('copipe-icon.png')}
						style={{
							width: 210,
							height: 210,
							opacity: icon,
							transform: `rotateY(${(1 - icon) * 160}deg) scale(${0.5 + icon * 0.5})`,
							filter: `drop-shadow(0 18px 50px rgba(255,150,40,${glow}))`,
						}}
					/>
				</div>
				<div style={{fontSize: 30, fontWeight: 600, letterSpacing: 6, opacity: sub, marginBottom: 0}}>使い方ガイド</div>
				<div
					style={{
						fontSize: 150,
						fontWeight: 800,
						letterSpacing: 4,
						transform: `scale(${0.7 + title * 0.3})`,
						opacity: title,
						background: 'linear-gradient(90deg, #ffffff, #b9c7ff 60%, #ffd6f5)',
						WebkitBackgroundClip: 'text',
						color: 'transparent',
						textShadow: '0 10px 50px rgba(120,140,255,0.35)',
					}}
				>
					Copipe
				</div>
				<div style={{fontSize: 46, fontWeight: 600, opacity: sub, transform: `translateY(${(1 - sub) * 20}px)`}}>
					コピーしたものを、全部覚えておく。
				</div>
			</AbsoluteFill>
		</AbsoluteFill>
	);
};

// MARK: - 1. 開く

export const Open: React.FC = () => {
	const offset = usePanelOffset(70);
	return (
		<SceneFade duration={DURATIONS.open}>
			<DocWindow title="メモ" lines={['会議のメモ', <span style={{color: '#b8b8c0'}}>ここに貼り付けたい…</span>]} />
			<Caption step={1} icon="tray" title="⌃⌘V で履歴を開く" sub="コピーした文字・画像・リンク・ファイルが、新しい順にカードで並びます。" />
			<Keys keys={['⌃|control', '⌘|command', 'V']} appearAt={22} pressAt={58} hideAt={140} />
			<ScaledPanel>
				<Panel cards={historyCards} selected={0} tabs={tabs} activeTab={0} offsetY={offset} />
			</ScaledPanel>
		</SceneFade>
	);
};

// MARK: - 2. 貼り付け

export const PasteScene: React.FC = () => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const selected = frame < 45 ? 0 : frame < 75 ? 1 : frame < 105 ? 2 : 1;
	const offset = usePanelOffset(-30, 160);
	// 選んだカードが書類へ飛んでいく
	const fly = spring({frame: frame - 152, fps, config: {damping: 20}});
	const from = cardOrigin(1);
	const pasted = frame > 182;
	const flash = interpolate(frame, [182, 200, 230], [0, 1, 0], clamp);
	return (
		<SceneFade duration={DURATIONS.paste}>
			<DocWindow
				title="メモ"
				lines={[
					'会議のメモ',
					pasted ? (
						<span style={{background: `rgba(10,132,255,${flash * 0.18})`, borderRadius: 6}}>店名：さくらコーヒー　営業時間：8:00〜18:00</span>
					) : (
						<span style={{color: '#b8b8c0'}}>ここに貼り付けたい…</span>
					),
				]}
			/>
			<Caption step={2} icon="cursor" title="選んで return で貼り付け" sub="← → でカードを選んで return。ダブルクリックや ⌘1〜9 でもすぐ貼り付けられます。" />
			<Keys keys={['→']} appearAt={30} pressAt={[45, 75]} hideAt={90} />
			<Keys keys={['←']} appearAt={95} pressAt={105} hideAt={125} />
			<Keys keys={['↵|return']} appearAt={128} pressAt={150} hideAt={178} />
			<ScaledPanel>
				<Panel cards={historyCards} selected={selected} tabs={tabs} activeTab={0} offsetY={offset} />
			</ScaledPanel>
			{frame >= 152 && frame < 190 ? (
				<div
					style={{
						position: 'absolute',
						left: interpolate(fly, [0, 1], [from.x, 560], clamp),
						top: interpolate(fly, [0, 1], [from.y, 360], clamp),
						transform: `scale(${interpolate(fly, [0, 1], [S, 0.35], clamp)})`,
						transformOrigin: 'top left',
						opacity: interpolate(frame, [176, 190], [1, 0], clamp),
					}}
				>
					<Card data={historyCards[1]} selected />
				</div>
			) : null}
		</SceneFade>
	);
};

// MARK: - 3. 探す

export const SearchScene: React.FC = () => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const query = 'こーひー'.slice(0, Math.max(0, Math.floor((frame - 30) / 9) + 1));
	const filter = spring({frame: frame - 75, fps, config: {damping: 20}});
	const bubble = spring({frame: frame - 110, fps, config: {damping: 14}});
	return (
		<SceneFade duration={DURATIONS.search}>
			<Caption step={3} icon="search" title="打つだけで探せる" sub="ひらがな・カタカナ、全角・半角を区別しません。画像の中の文字でも見つかります。" />
			<ScaledPanel>
				<Panel
					cards={historyCards}
					selected={filter > 0.5 ? 1 : undefined}
					search={frame >= 30 ? query : ''}
					tabs={tabs}
					activeTab={0}
					cardStyle={(i) =>
						i === 1
							? {}
							: {width: CARD_W * (1 - filter), marginRight: -16 * filter, opacity: 1 - filter, transform: `scale(${1 - filter * 0.3})`}
					}
				/>
			</ScaledPanel>
			<div
				style={{
					position: 'absolute',
					left: 420,
					top: PANEL_TOP - 150,
					padding: '22px 34px',
					borderRadius: 24,
					background: 'white',
					boxShadow: '0 14px 40px rgba(0,0,0,0.35)',
					fontFamily: font,
					fontSize: 36,
					fontWeight: 700,
					color: colors.ink,
					opacity: bubble,
					transform: `translateY(${(1 - bubble) * 20}px)`,
				}}
			>
				「こーひー」で <span style={{color: colors.accent}}>「コーヒー」</span> も見つかる
			</div>
		</SceneFade>
	);
};

// MARK: - 4. ピンボード

export const PinboardScene: React.FC = () => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const lift = spring({frame: frame - 30, fps, config: {damping: 14}});
	const fly = spring({frame: frame - 60, fps, config: {damping: 20}});
	const showBoard = frame >= 140;
	const swap = interpolate(frame, [140, 155], [0, 1], clamp);
	const pulse = interpolate(frame, [95, 110, 130], [0, 1, 0], clamp);
	const from = cardOrigin(1);
	// 「定型文」のタブ（画面の上での位置）
	const tabX = 926;
	const tabY = PANEL_TOP + 27 * S;
	return (
		<SceneFade duration={DURATIONS.pinboard}>
			<Caption step={4} icon="pin" title="ピンボードに取っておく" sub="よく使うものは、名前と色の付いたピンボードへ。⌃⌘1〜9 ですぐ開けます。" />
			<Keys keys={['⌃|control', '⌘|command', '1']} appearAt={170} pressAt={195} hideAt={240} />
			<ScaledPanel>
				<Panel
					cards={showBoard ? pinnedCards : historyCards}
					tabs={tabs}
					activeTab={showBoard ? 1 : 0}
					selected={showBoard ? 2 : undefined}
					tabStyle={(i) => (i === 1 ? {background: `rgba(10,132,255,${0.12 + pulse * 0.35})`, transform: `scale(${1 + pulse * 0.15})`} : {})}
					cardStyle={(i) =>
						showBoard
							? {opacity: swap, transform: `translateY(${(1 - swap) * 20}px)`}
							: i === 1
								? {opacity: frame >= 60 ? 0.35 : 1, transform: `translateY(${-lift * 24}px) scale(${1 + lift * 0.04})`}
								: {}
					}
				/>
			</ScaledPanel>
			{frame >= 60 && frame < 120 ? (
				<div
					style={{
						position: 'absolute',
						left: interpolate(fly, [0, 1], [from.x, tabX - 30], clamp),
						top: interpolate(fly, [0, 1], [from.y - lift * 24 * S, tabY - 20], clamp),
						transform: `scale(${interpolate(fly, [0, 1], [S, 0.2], clamp)})`,
						transformOrigin: 'top left',
						opacity: interpolate(frame, [100, 118], [1, 0], clamp),
					}}
				>
					<Card data={historyCards[1]} />
				</div>
			) : null}
		</SceneFade>
	);
};

// MARK: - 5. 整えて貼り付け

const pdfText: typeof historyCards[number] = {
	id: 'pdf',
	kind: 'text',
	title: 'テキスト',
	time: 'たった今',
	icon: 'doc',
	body: '新しいカタログは\n来月から店頭で\n配布します。',
	footer: 'PDF からコピー',
};

export const TransformScene: React.FC = () => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const offset = usePanelOffset(-30, 125);
	const menu = spring({frame: frame - 58, fps, config: {damping: 16}});
	const highlight = frame >= 85 ? 0 : -1;
	const chosen = interpolate(frame, [108, 112, 116, 120], [0, 1, 0, 1], clamp);
	const pasted = frame >= 140;
	const items = ['改行を消して貼り付け', '英数字を半角にして貼り付け', '英数字を全角にして貼り付け', '前後の空白を取って貼り付け', '「」で囲んで貼り付け'];
	const cards = [pdfText, ...historyCards.slice(0, 5)];
	return (
		<SceneFade duration={DURATIONS.transform}>
			<DocWindow
				title="資料"
				lines={[
					'お知らせの下書き',
					pasted ? (
						<span style={{opacity: interpolate(frame, [140, 150], [0, 1], clamp)}}>新しいカタログは来月から店頭で配布します。</span>
					) : (
						<span style={{color: '#b8b8c0'}}>（PDF からコピーした文章は、行の途中で切れてしまう…）</span>
					),
				]}
			/>
			<Caption step={5} icon="wand" title="整えて貼り付け" sub="option + return で、改行を消す・英数字を半角に・前後の空白を取る などをしてから貼り付け。" />
			<Keys keys={['⌥|option', '↵|return']} appearAt={22} pressAt={48} hideAt={70} top={300} />
			<ScaledPanel>
				<Panel cards={cards} selected={0} tabs={tabs} activeTab={0} offsetY={offset} />
			</ScaledPanel>
			{frame >= 58 && frame < 128 ? (
				<div
					style={{
						position: 'absolute',
						left: cardOrigin(0).x + 40,
						top: cardOrigin(0).y - 310,
						width: 470,
						padding: 8,
						borderRadius: 14,
						background: 'rgba(250,250,252,0.97)',
						boxShadow: '0 14px 40px rgba(0,0,0,0.35)',
						fontFamily: font,
						fontSize: 26,
						opacity: menu * interpolate(frame, [118, 128], [1, 0], clamp),
						transform: `scale(${0.9 + menu * 0.1})`,
						transformOrigin: 'bottom left',
					}}
				>
					{items.map((item, i) => (
						<div
							key={item}
							style={{
								padding: '8px 16px',
								borderRadius: 8,
								color: i === highlight ? 'white' : colors.ink,
								background: i === highlight ? (chosen > 0.5 ? '#5aa9ff' : colors.accent) : 'transparent',
							}}
						>
							{item}
						</div>
					))}
				</div>
			) : null}
		</SceneFade>
	);
};

// MARK: - 6. Final Cut Pro の素材

export const FinalCutScene: React.FC = () => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const pop = spring({frame: frame - 45, fps, config: {damping: 13}});
	const detail = spring({frame: frame - 85, fps, config: {damping: 18}});
	const clips = [
		{w: 260, c: '#5b8def', name: 'オープニング映像'},
		{w: 180, c: '#a46cf0', name: 'テロップ'},
		{w: 320, c: '#5b8def', name: '本編'},
		{w: 220, c: '#e0a23b', name: 'BGM'},
	];
	const selectedClip = interpolate(frame, [15, 25], [0, 1], clamp);
	return (
		<SceneFade duration={DURATIONS.fcp}>
			<Caption step={6} icon="film" title="Final Cut Pro の素材も" sub="タイムラインでコピーしたクリップやテロップを保存。中身が見えて、そのまま貼り戻せます。" />
			{/* タイムラインの見本 */}
			<div style={{position: 'absolute', left: 160, right: 160, bottom: 90, height: 150, borderRadius: 16, background: 'rgba(20,22,35,0.85)', padding: 24, display: 'flex', gap: 8, alignItems: 'center', fontFamily: font}}>
				{clips.map((clip, i) => (
					<div
						key={clip.name}
						style={{
							width: clip.w,
							height: 70,
							borderRadius: 8,
							background: clip.c,
							color: 'white',
							fontSize: 20,
							padding: '8px 12px',
							boxShadow: i < 2 ? `0 0 0 ${selectedClip * 4}px #ffd60a` : undefined,
						}}
					>
						{clip.name}
					</div>
				))}
			</div>
			<Keys keys={['⌘|command', 'C']} appearAt={10} pressAt={30} hideAt={60} top={760} />
			<div style={{position: 'absolute', left: 260, top: 330, transform: `scale(${pop * 1.5})`, transformOrigin: 'top left', opacity: pop}}>
				<Card data={fcpCard} selected />
			</div>
			<div
				style={{
					position: 'absolute',
					left: 760,
					top: 330,
					width: 900,
					height: 384,
					borderRadius: 18,
					background: 'rgba(245,245,248,0.97)',
					boxShadow: '0 20px 60px rgba(0,0,0,0.4)',
					fontFamily: font,
					padding: '26px 34px',
					opacity: detail,
					transform: `translateX(${(1 - detail) * 60}px)`,
					color: colors.ink,
				}}
			>
				<div style={{display: 'flex', alignItems: 'center', gap: 10, fontSize: 30, fontWeight: 800, marginBottom: 14}}>
					<Icon name="clock" size={30} color={colors.accent} />長さ {fcpCard.fcp!.duration}
				</div>
				<div style={{fontSize: 20, color: colors.sub, fontWeight: 700}}>クリップ・テロップ</div>
				{fcpCard.fcp!.names.map((name) => (
					<div key={name} style={{display: 'flex', alignItems: 'center', gap: 10, fontSize: 30, margin: '6px 0'}}>
						<Icon name="film" size={28} color={colors.sub} />
						{name}
					</div>
				))}
				<div style={{fontSize: 20, color: colors.sub, fontWeight: 700, marginTop: 12}}>エフェクト・タイトル</div>
				<div style={{display: 'flex', alignItems: 'center', gap: 10, fontSize: 30, marginTop: 6}}>
					<Icon name="sparkles" size={28} color="#bf5af2" />
					{fcpCard.fcp!.effects.join('・')}
				</div>
			</div>
		</SceneFade>
	);
};

// MARK: - 7. ペーストスタック

export const StackScene: React.FC = () => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const values = ['見本株式会社', '山田 太郎', 'yamada@example.com'];
	const labels = ['会社名', '名前', 'メール'];
	const copyAt = [80, 120, 160];
	const pasteAt = [205, 235, 265];
	const panelIn = spring({frame: frame - 45, fps, config: {damping: 18}});
	const copied = copyAt.filter((at) => frame >= at).length;
	const pastedCount = pasteAt.filter((at) => frame >= at + 6).length;
	const stack = values.slice(pastedCount, copied);
	return (
		<SceneFade duration={DURATIONS.stack}>
			<Caption step={7} icon="stack" title="ペーストスタック" sub="⌃⌘C で始めて続けてコピー。⌘V を押すたびに、コピーした順に1つずつ貼り付けます。" />
			<Keys keys={['⌃|control', '⌘|command', 'C']} appearAt={8} pressAt={28} hideAt={60} top={760} />
			<Keys keys={['⌘|command', 'V']} appearAt={190} pressAt={pasteAt} hideAt={285} top={760} />
			{/* コピー元 */}
			<DocWindow
				title="名刺のメモ"
				style={{left: 120, width: 600, top: 300, height: 300}}
				lines={values.map((v, i) => (
					<span key={v} style={{background: frame >= copyAt[i] && frame < copyAt[i] + 25 ? 'rgba(10,132,255,0.28)' : 'transparent', borderRadius: 6}}>
						{v}
					</span>
				))}
			/>
			{/* 貼り付け先 */}
			<DocWindow
				title="お問い合わせフォーム"
				style={{left: 760, width: 620, top: 300, height: 300}}
				lines={labels.map((label, i) => (
					<div key={label} style={{display: 'flex', gap: 16, alignItems: 'center', marginBottom: 6}}>
						<div style={{width: 100, fontSize: 22, color: colors.sub}}>{label}</div>
						<div style={{flex: 1, height: 46, borderRadius: 8, border: '2px solid #d6d6de', padding: '0 12px', fontSize: 24, display: 'flex', alignItems: 'center'}}>
							{frame >= pasteAt[i] + 6 ? values[i] : ''}
						</div>
					</div>
				))}
			/>
			{/* ペーストスタックの窓 */}
			<div
				style={{
					position: 'absolute',
					left: interpolate(panelIn, [0, 1], [1940, 1420], clamp),
					top: 260,
					width: 420,
					height: 440,
					borderRadius: 20,
					background: 'rgba(240,241,246,0.95)',
					boxShadow: '0 20px 60px rgba(0,0,0,0.4)',
					padding: 20,
					fontFamily: font,
				}}
			>
				<div style={{display: 'flex', alignItems: 'center', gap: 10, fontSize: 24, fontWeight: 800, color: colors.ink, marginBottom: 14}}>
					<IconTile name="stack" size={34} />ペーストスタック
				</div>
				{stack.length === 0 ? (
					<div style={{fontSize: 21, color: colors.sub, lineHeight: 1.6, marginTop: 60, textAlign: 'center'}}>
						コピーすると、ここにたまります
					</div>
				) : null}
				{stack.map((value, i) => {
					const index = values.indexOf(value);
					const enter = spring({frame: frame - copyAt[index], fps, config: {damping: 16}});
					return (
						<div
							key={value}
							style={{
								display: 'flex',
								alignItems: 'center',
								gap: 12,
								padding: 12,
								marginBottom: 10,
								borderRadius: 12,
								background: 'white',
								fontSize: 24,
								color: colors.ink,
								opacity: enter,
								transform: `translateX(${(1 - enter) * -40}px)`,
							}}
						>
							<div style={{width: 34, height: 34, borderRadius: 17, background: i === 0 ? colors.accent : '#dcdde3', color: i === 0 ? 'white' : colors.ink, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 18, fontWeight: 800}}>
								{i + 1}
							</div>
							{value}
						</div>
					);
				})}
			</div>
		</SceneFade>
	);
};

// MARK: - おわり

export const Outro: React.FC = () => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const title = spring({frame: frame - 40, fps, config: {damping: 15}});
	const chips: [IconName, string][] = [
		['tray', '⌃⌘V で開く'],
		['search', '打つだけで探せる'],
		['pin', 'ピンボード'],
		['wand', '整えて貼り付け'],
		['film', 'Final Cut Pro の素材'],
		['stack', 'ペーストスタック'],
	];
	const out = interpolate(frame, [215, 240], [1, 0], clamp);
	return (
		<AbsoluteFill style={{opacity: interpolate(frame, [0, 12], [0, 1], clamp) * out}}>
			<Space mode="outro" />
			<AbsoluteFill style={{background: `rgba(8,10,30,${title * 0.62})`}} />
			<AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', fontFamily: font, color: 'white'}}>
				<div style={{display: 'flex', alignItems: 'center', gap: 36, opacity: title, transform: `scale(${0.8 + title * 0.2})`}}>
					<Img src={staticFile('copipe-icon.png')} style={{width: 170, height: 170, filter: 'drop-shadow(0 14px 40px rgba(255,150,40,0.4))'}} />
					<div style={{fontSize: 150, fontWeight: 800}}>Copipe</div>
				</div>
				<div style={{fontSize: 44, fontWeight: 600, opacity: title, marginTop: 4, textShadow: '0 3px 14px rgba(0,0,0,0.7)'}}>コピーしたものを、全部覚えておく。</div>
				<div style={{display: 'flex', flexWrap: 'wrap', justifyContent: 'center', gap: 16, marginTop: 50, maxWidth: 1400}}>
					{chips.map(([icon, chip], i) => {
						const p = spring({frame: frame - 80 - i * 7, fps, config: {damping: 14}});
						return (
							<div
								key={chip}
								style={{
									display: 'flex',
									alignItems: 'center',
									gap: 12,
									padding: '12px 28px 12px 14px',
									borderRadius: 40,
									fontSize: 30,
									fontWeight: 700,
									background: 'rgba(20,24,60,0.75)',
									border: `3px solid ${palette[i % palette.length]}`,
									opacity: p,
									transform: `translateY(${(1 - p) * 24}px)`,
								}}
							>
								<IconTile name={icon} size={42} />
								{chip}
							</div>
						);
					})}
				</div>
				<div style={{display: 'flex', alignItems: 'center', gap: 10, fontSize: 26, opacity: interpolate(frame, [140, 160], [0, 0.85], clamp), marginTop: 50}}>
					<Icon name="shield" size={28} color="#9be7a4" />
					macOS 14 以降 ・ コピーした中身はこの Mac の中だけに保存
				</div>
			</AbsoluteFill>
		</AbsoluteFill>
	);
};

export {CARD_H};
