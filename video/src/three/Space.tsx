import {ThreeCanvas} from '@remotion/three';
import {useThree} from '@react-three/fiber';
import React, {useMemo} from 'react';
import {interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import * as THREE from 'three';
import {clamp, palette} from '../theme';

/** 宇宙に浮かぶカード。intro は奥から飛んでくる、outro は並んで整列する、background はゆっくり漂う */
export type SpaceMode = 'intro' | 'background' | 'outro';

const CARD_COUNT = 30;

/** 毎回同じ並びになる乱数 */
const seeded = (seed: number) => {
	let s = seed;
	return () => {
		s = (s * 16807) % 2147483647;
		return (s - 1) / 2147483646;
	};
};

const roundedCard = (w: number, h: number, r: number) => {
	const shape = new THREE.Shape();
	shape.moveTo(-w / 2 + r, -h / 2);
	shape.lineTo(w / 2 - r, -h / 2);
	shape.quadraticCurveTo(w / 2, -h / 2, w / 2, -h / 2 + r);
	shape.lineTo(w / 2, h / 2 - r);
	shape.quadraticCurveTo(w / 2, h / 2, w / 2 - r, h / 2);
	shape.lineTo(-w / 2 + r, h / 2);
	shape.quadraticCurveTo(-w / 2, h / 2, -w / 2, h / 2 - r);
	shape.lineTo(-w / 2, -h / 2 + r);
	shape.quadraticCurveTo(-w / 2, -h / 2, -w / 2 + r, -h / 2);
	const geometry = new THREE.ShapeGeometry(shape, 10);
	// テクスチャを貼るために UV を 0〜1 にそろえる
	const uv = geometry.attributes.uv;
	for (let i = 0; i < uv.count; i++) {
		uv.setXY(i, (uv.getX(i) + w / 2) / w, (uv.getY(i) + h / 2) / h);
	}
	return geometry;
};

/** カードの絵（白い地に、色の丸・見出し・文字の行のかたち）を canvas で描く */
const cardTexture = (color: string, variant: number) => {
	const canvas = document.createElement('canvas');
	canvas.width = 256;
	canvas.height = 272;
	const ctx = canvas.getContext('2d')!;
	ctx.fillStyle = '#ffffff';
	ctx.fillRect(0, 0, 256, 272);
	if (variant % 3 === 1) {
		// 画像のカード
		const g = ctx.createLinearGradient(0, 0, 256, 272);
		g.addColorStop(0, color);
		g.addColorStop(1, '#1b1f3b');
		ctx.fillStyle = g;
		ctx.fillRect(0, 0, 256, 272);
		ctx.fillStyle = 'rgba(255,255,255,0.85)';
		ctx.fillRect(18, 20, 70, 12);
	} else {
		ctx.fillStyle = color;
		ctx.beginPath();
		ctx.arc(26, 28, 8, 0, Math.PI * 2);
		ctx.fill();
		ctx.fillStyle = '#1f2330';
		ctx.fillRect(42, 21, 80, 14);
		ctx.fillStyle = '#c9ccd6';
		for (let i = 0; i < 6; i++) {
			const width = 200 - ((i * 37 + variant * 13) % 90);
			ctx.fillRect(18, 64 + i * 26, width, 10);
		}
		ctx.fillStyle = color;
		ctx.globalAlpha = 0.25;
		ctx.fillRect(0, 0, 256, 272);
	}
	const texture = new THREE.CanvasTexture(canvas);
	texture.colorSpace = THREE.SRGBColorSpace;
	texture.anisotropy = 8;
	return texture;
};

const CameraRig: React.FC<{mode: SpaceMode}> = ({mode}) => {
	const frame = useCurrentFrame();
	const {camera} = useThree();
	const z =
		mode === 'intro'
			? interpolate(frame, [0, 150], [16, 11], clamp)
			: mode === 'outro'
				? interpolate(frame, [0, 240], [13, 11.5], clamp)
				: 12;
	camera.position.set(Math.sin(frame / 160) * 0.8, Math.cos(frame / 200) * 0.4, z);
	camera.lookAt(0, 0, 0);
	return null;
};

const Cards: React.FC<{mode: SpaceMode}> = ({mode}) => {
	const frame = useCurrentFrame();
	const {fps} = useVideoConfig();
	const geometry = useMemo(() => roundedCard(1.6, 1.7, 0.14), []);
	const cards = useMemo(() => {
		const rand = seeded(7);
		return Array.from({length: CARD_COUNT}, (_, i) => {
			const color = palette[i % palette.length];
			return {
				texture: cardTexture(color, i),
				x: (rand() - 0.5) * 22,
				y: (rand() - 0.5) * 11,
				z: -rand() * 14 - 1,
				spin: (rand() - 0.5) * 0.6,
				phase: rand() * Math.PI * 2,
				speed: 0.6 + rand() * 0.8,
			};
		});
	}, []);

	return (
		<>
			{cards.map((card, i) => {
				const drift = Math.sin(frame / 45 * card.speed + card.phase) * 0.35;
				let x = card.x;
				let y = card.y + drift;
				let z = card.z;
				let rotY = Math.sin(frame / 90 + card.phase) * 0.35 + card.spin;
				let rotZ = Math.sin(frame / 120 + card.phase) * 0.08;

				if (mode === 'intro') {
					// 奥から順に飛んでくる
					const p = spring({frame: frame - i * 2, fps, config: {damping: 18, mass: 0.9}});
					z = interpolate(p, [0, 1], [-60, card.z], clamp);
					rotY += (1 - p) * 2.4;
				}
				if (mode === 'outro') {
					// 6 × 3 に並んで、Copipe の画面のように整列する（残りは奥で漂う）
					if (i < 18) {
						const col = i % 6;
						const row = Math.floor(i / 6);
						const p = spring({frame: frame - 10 - i * 2, fps, config: {damping: 20}});
						const gx = (col - 2.5) * 1.9;
						const gy = (1 - row) * 2 - 0.9;
						x = interpolate(p, [0, 1], [card.x, gx], clamp);
						y = interpolate(p, [0, 1], [card.y + drift, gy + drift * 0.15], clamp);
						z = interpolate(p, [0, 1], [card.z, -2], clamp);
						rotY = interpolate(p, [0, 1], [rotY, 0], clamp);
						rotZ = interpolate(p, [0, 1], [rotZ, 0], clamp);
					} else {
						z -= 6;
					}
				}
				const opacity = mode === 'background' ? 0.55 : 1;
				return (
					<mesh key={i} geometry={geometry} position={[x, y, z]} rotation={[0, rotY, rotZ]}>
						<meshStandardMaterial map={card.texture} roughness={0.45} metalness={0.05} transparent opacity={opacity} side={THREE.DoubleSide} />
					</mesh>
				);
			})}
		</>
	);
};

/** 小さな光の粒 */
const Dust: React.FC = () => {
	const frame = useCurrentFrame();
	const geometry = useMemo(() => {
		const rand = seeded(42);
		const points = new Float32Array(600 * 3);
		for (let i = 0; i < 600; i++) {
			points[i * 3] = (rand() - 0.5) * 40;
			points[i * 3 + 1] = (rand() - 0.5) * 24;
			points[i * 3 + 2] = -rand() * 30;
		}
		const g = new THREE.BufferGeometry();
		g.setAttribute('position', new THREE.BufferAttribute(points, 3));
		return g;
	}, []);
	return (
		<points geometry={geometry} rotation={[0, frame / 900, 0]}>
			<pointsMaterial color="#cfd8ff" size={0.05} transparent opacity={0.7} />
		</points>
	);
};

export const Space: React.FC<{mode: SpaceMode}> = ({mode}) => {
	const {width, height} = useVideoConfig();
	return (
		<ThreeCanvas width={width} height={height} gl={{antialias: true, alpha: true}} camera={{fov: 45, position: [0, 0, 12]}}>
			<CameraRig mode={mode} />
			<ambientLight intensity={1.6} />
			<directionalLight position={[4, 6, 8]} intensity={1.4} />
			<pointLight position={[-6, -3, 4]} intensity={30} color="#8a7dff" />
			<Dust />
			<Cards mode={mode} />
		</ThreeCanvas>
	);
};
