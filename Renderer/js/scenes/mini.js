// Mini player: just the record (and optionally a tonearm) floating on the
// desktop, seen from directly above. The window around it is transparent.
import * as THREE from 'three';
import { BaseScene } from './base.js';
import { createTurntable } from '../models/turntable.js';
import { contactPlane } from '../models/props.js';
import { RECORD_RADIUS } from '../textures.js';

// Content bounds (metres, top-down). Native sizes the window to this aspect.
const M = RECORD_RADIUS * 1.08;
const MINI_BOUNDS = { x0: -M, x1: M, z0: -M, z1: M };
const MINI_BOUNDS_WITH_ARM = { x0: -M, x1: 0.255, z0: -M, z1: M };

export class MiniScene extends BaseScene {
  constructor(ctx, options) {
    super(ctx, options);
    this.scene.environmentIntensity = 0.9;
    this.camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.01, 5);
    this.#build();
  }

  #build() {
    if (this.root) {
      this.scene.remove(this.root);
      // Materials don't own their maps, so artwork textures survive this.
      this.root.traverse((o) => {
        o.geometry?.dispose();
        o.material?.dispose();
      });
    }
    const root = (this.root = new THREE.Group());
    this.scene.add(root);
    const tt = (this.turntable = createTurntable({
      style: 'none',
      labelStyle: this.options.labelStyle || 'label',
      envMap: this.ctx.envMap,
      recordReflections: 0.12,
    }));
    root.add(tt.group);
    const showArm = this.options.tonearm !== false;
    tt.group.traverse((o) => {
      if (o.parent === tt.group && o !== tt.spin) o.visible = showArm;
    });
    // Drop shadow under the disc
    const shadow = contactPlane('round', RECORD_RADIUS * 2.5, RECORD_RADIUS * 2.5, 0.55);
    shadow.position.set(0.006, -0.002, 0.012);
    root.add(shadow);
    this.shadowCatcher = new THREE.Mesh(
      new THREE.PlaneGeometry(1, 1).rotateX(-Math.PI / 2),
      new THREE.ShadowMaterial({ opacity: 0.28 })
    );
    this.shadowCatcher.position.y = -0.001;
    this.shadowCatcher.receiveShadow = true;
    root.add(this.shadowCatcher);

    if (!this.key) {
      const key = (this.key = new THREE.DirectionalLight(0xffffff, 1.6));
      key.position.set(-0.55, 0.9, -0.45);
      key.castShadow = true;
      key.shadow.mapSize.set(1024, 1024);
      key.shadow.camera.left = -0.3;
      key.shadow.camera.right = 0.3;
      key.shadow.camera.top = 0.3;
      key.shadow.camera.bottom = -0.3;
      key.shadow.bias = -0.0005;
      key.shadow.radius = 4;
      this.scene.add(key, new THREE.HemisphereLight(0xffffff, 0x8a8a8a, 1.0));
    }
    this.layout();
    this.shadowsDirty = true;
  }

  setOption(key, value) {
    const changed = this.options[key] !== value;
    super.setOption(key, value);
    if (changed && (key === 'labelStyle' || key === 'tonearm')) {
      const art = this.currentArt;
      this.#build();
      if (art) this.turntable.setArt(art, true);
      if (this.lastPlayer) this.turntable.snapArm(this.lastPlayer);
    }
  }

  setTrackArt(tex, immediate) {
    this.currentArt = tex;
    super.setTrackArt(tex, immediate);
  }

  layout() {
    const aspect = this.width / this.height || 1;
    // Fit the record (plus the tonearm on its right) with a small margin.
    const b = this.options.tonearm !== false ? MINI_BOUNDS_WITH_ARM : MINI_BOUNDS;
    const cx = (b.x0 + b.x1) / 2;
    const cz = (b.z0 + b.z1) / 2;
    let hw = (b.x1 - b.x0) / 2;
    let hh = (b.z1 - b.z0) / 2;
    if (hw / hh > aspect) hh = hw / aspect;
    else hw = hh * aspect;
    Object.assign(this.camera, { left: -hw, right: hw, top: hh, bottom: -hh });
    this.camera.position.set(cx, 1, cz);
    this.camera.up.set(0, 0, -1);
    this.camera.lookAt(cx, 0, cz);
    this.camera.updateProjectionMatrix();
  }

  update(dt, time, player) {
    this.lastPlayer = player;
    super.update(dt, time, player);
  }
}
