import * as THREE from 'three';

// Common plumbing for every scene. Subclasses build their objects in the
// constructor and implement the hooks they care about.
export class BaseScene {
  constructor(ctx, options) {
    this.ctx = ctx;
    this.options = { ...options };
    this.scene = new THREE.Scene();
    this.scene.environment = ctx.envMap;
    this.width = 1;
    this.height = 1;
    this.shadowsDirty = true;
    this.turntable = null;
  }

  // ---- hooks -------------------------------------------------------------
  setTrackArt(texture, immediate = false) {
    this.turntable?.setArt(texture, immediate);
    this.shadowsDirty = true;
  }
  setRecentArt(_textures, _immediate) {}
  setNowPlaying(title, artist) {
    this.turntable?.setNameplate(title, artist);
  }
  setFraming(framing) {
    this.options.framing = framing;
    this.layout();
  }
  setBackground(on) {
    this.options.background = on;
  }
  setOption(key, value) {
    this.options[key] = value;
  }
  layout() {}
  update(dt, time, player) {
    if (this.turntable) {
      const s = this.turntable.update(dt, player);
      if (s.armMoved) this.shadowsDirty = true;
    }
  }
  snapToState(player) {
    this.turntable?.snapArm(player);
    this.shadowsDirty = true;
  }

  resize(w, h) {
    this.width = w;
    this.height = h;
    this.layout();
    this.shadowsDirty = true;
  }

  render(renderer) {
    if (this.shadowsDirty) {
      renderer.shadowMap.needsUpdate = true;
      this.shadowsDirty = false;
    }
    renderer.render(this.scene, this.camera);
  }

  dispose() {
    this.scene.traverse((o) => {
      if (o.geometry) o.geometry.dispose();
      if (o.material) {
        const mats = Array.isArray(o.material) ? o.material : [o.material];
        mats.forEach((m) => m.dispose());
      }
      if (o.isLight && o.shadow && o.shadow.map) o.shadow.map.dispose();
    });
  }
}

// Perspective camera looking straight ahead (level), with the view shifted
// vertically like a tilt-shift lens so verticals stay vertical.
export function setShiftedFrustum(camera, { tanHalfWidth, aspect, shift, near = 0.05, far = 30 }) {
  const tanHalfHeight = tanHalfWidth / aspect;
  const top = (shift + tanHalfHeight) * near;
  const bottom = (shift - tanHalfHeight) * near;
  const right = tanHalfWidth * near;
  camera.near = near;
  camera.far = far;
  camera.projectionMatrix.makePerspective(-right, right, top, bottom, near, far);
  camera.projectionMatrixInverse.copy(camera.projectionMatrix).invert();
}
