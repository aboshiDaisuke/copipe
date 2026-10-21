import type {CardData, Tab} from './ui';
import {palette} from './theme';

// 動画に出す見本のカード（実在の人・会社の情報や、実際の履歴・ピンボードの中身は使わない）

export const tabs: Tab[] = [
	{name: 'クリップボード', color: '#8E8E93'},
	{name: '定型文', color: palette[5]},
	{name: '素材', color: palette[6]},
	{name: '資料', color: palette[3]},
];

export const historyCards: CardData[] = [
	{id: 'greet', kind: 'text', title: 'テキスト', time: 'たった今', icon: 'note', body: 'いつもお世話になっております。\n見本株式会社の山田です。\n先日はありがとうございました。', footer: '42 文字'},
	{id: 'cafe', kind: 'text', title: 'テキスト', time: '3 分前', icon: 'note', body: '店名：さくらコーヒー\n営業時間：8:00〜18:00', footer: '24 文字'},
	{id: 'photo', kind: 'image', title: '画像', time: '8 分前', icon: 'image', art: 'radial-gradient(circle at 30% 30%, #ffd27a, #ff7a59 45%, #5b3cc4 100%)', footer: '1920 × 1080'},
	{id: 'link', kind: 'link', title: 'リンク', time: '15 分前', icon: 'globe', art: 'linear-gradient(135deg, #43e0b2, #2f7bff)', body: '週末のおでかけガイド', footer: 'example.com'},
	{id: 'color', kind: 'color', title: '色', time: '21 分前', icon: 'palette', body: '#3498DB'},
	{id: 'file', kind: 'file', title: 'ファイル', time: '30 分前', icon: 'folder', body: '企画書_v3.pdf', footer: '企画書_v3.pdf'},
	{id: 'addr', kind: 'text', title: 'テキスト', time: '1 時間前', icon: 'note', body: '〒100-0000\n東京都千代田区見本町 1-2-3', footer: '25 文字'},
];

export const pinnedCards: CardData[] = [
	{id: 'p1', kind: 'text', title: 'あいさつ', time: '2 日前', icon: 'note', body: 'いつもお世話になっております。\n見本株式会社の山田です。', footer: '30 文字', board: palette[5]},
	{id: 'p2', kind: 'text', title: '日報の書き出し', time: '1 週間前', icon: 'note', body: '{今日}（{曜日}）の作業報告です。', footer: '日付が自動で入る', board: palette[5]},
	{id: 'p3', kind: 'text', title: 'お店の情報', time: 'たった今', icon: 'note', body: '店名：さくらコーヒー\n営業時間：8:00〜18:00', footer: '24 文字', board: palette[5]},
];

export const fcpCard: CardData = {
	id: 'fcp',
	kind: 'fcp',
	title: 'オープニング',
	time: '5 分前',
	icon: 'clapper',
	board: palette[6],
	fcp: {names: ['オープニング映像', 'テロップ：タイトル', 'BGM_明るい'], effects: ['クロスディゾルブ', '基本タイトル'], duration: '12.4 秒'},
	footer: '12.4 秒 ・ 38 KB',
};
