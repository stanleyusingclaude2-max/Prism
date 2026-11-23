import Foundation

enum UploadPage {
    static let html = #"""
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="color-scheme" content="dark">
  <title>Prism · 传文件到 iPhone</title>
  <style>
    @font-face{font-family:"D-DIN";font-style:normal;font-weight:400;src:url("fonts/D-DIN.otf") format("opentype");font-display:swap}
    @font-face{font-family:"D-DIN";font-style:normal;font-weight:700;src:url("fonts/D-DIN-Bold.otf") format("opentype");font-display:swap}
    :root{color-scheme:dark;--bg:#0d1014;--surface:#171c22;--raised:#242b33;--line:#2c343d;--text:#f4f6f8;--muted:#9aa5b1;--accent:#9edcff;--success:#9ad8ad;--danger:#ff998b}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.6 "D-DIN",-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}button,input{font:inherit}button{cursor:pointer}button:focus-visible,[tabindex]:focus-visible{outline:3px solid var(--accent);outline-offset:5px}button:disabled{cursor:default;opacity:.45}.wrap{max-width:1080px;margin:0 auto;padding:42px 28px 56px}header{display:flex;justify-content:space-between;align-items:center;margin-bottom:48px}.logo{font-size:38px;line-height:1;font-weight:700;letter-spacing:-1.8px;color:var(--accent);text-decoration:none}.status{display:inline-flex;align-items:center;gap:8px;padding:7px 13px;border-radius:99px;background:#1c3443;color:var(--accent);font-size:12px}.dot{width:6px;height:6px;background:currentColor;border-radius:50%}.status.offline{background:var(--raised);color:var(--muted)}h1{font-size:30px;line-height:1.4;letter-spacing:-.5px;margin:0 0 8px}p{margin:0}.lead{color:var(--muted);margin-bottom:28px}.columns{display:grid;grid-template-columns:minmax(0,1fr) 260px;gap:24px}.drop{min-height:255px;border:1px dashed #405e70;border-radius:20px;background:var(--surface);display:flex;flex-direction:column;justify-content:center;align-items:center;text-align:center;padding:32px 20px;gap:11px;transition:border-color .15s,background .15s}.drop.dragging{border-color:var(--accent);background:#1c3443}.drop svg{width:36px;height:36px;color:var(--accent);margin-bottom:4px}.drop h2{font-size:20px;line-height:1.4;margin:0}.drop p{color:var(--muted);font-size:13px}.primary{border:0;border-radius:11px;background:var(--accent);color:#102431;font-weight:700;padding:10px 24px;min-height:44px;margin-top:8px}.aside{border:1px solid var(--line);background:var(--surface);border-radius:20px;padding:23px}.eyebrow{font-size:12px;color:var(--muted)}.capacity{font-size:27px;font-weight:700;letter-spacing:-.5px;margin:4px 0 22px;font-variant-numeric:tabular-nums}.aside h2{font-size:14px;margin:0 0 12px}.steps{padding-left:19px;color:var(--muted);font-size:13px;margin:0}.steps li{margin:10px 0}.aside .note{border-top:1px solid var(--line);padding-top:16px;margin-top:20px;font-size:12px;color:var(--muted)}.queueHeader{display:flex;justify-content:space-between;align-items:center;gap:12px;margin:32px 0 14px}.queueHeader h2{font-size:16px;margin:0}.queueSummary{font-size:12px;color:var(--muted)}.empty{padding:25px;border:1px solid var(--line);border-radius:14px;color:var(--muted);font-size:13px;text-align:center}.queue{display:flex;flex-direction:column;gap:10px}.file{background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:15px 16px}.fileTop{display:flex;align-items:flex-start;gap:12px}.fileIcon{font-size:20px;color:var(--muted);line-height:24px}.fileDetails{flex:1;min-width:0}.fileName{font-size:14px;font-weight:700;overflow-wrap:anywhere;line-height:1.6}.fileMeta{color:var(--muted);font-size:12px;margin-top:3px;font-variant-numeric:tabular-nums}.fileState{font-size:12px;color:var(--accent);white-space:nowrap;padding-top:2px}.file.completed .fileState{color:var(--success)}.file.failed .fileState,.file.failed .fileMeta{color:var(--danger)}.file.cancelled .fileState{color:var(--muted)}.fileActions{display:flex;gap:8px;align-items:center;margin-left:6px}.secondary{border:1px solid var(--line);border-radius:8px;min-height:36px;background:var(--raised);color:var(--text);padding:5px 10px;font-size:12px}.cancel{background:transparent;color:var(--muted)}progress{appearance:none;-webkit-appearance:none;display:block;width:100%;height:4px;border:0;border-radius:4px;overflow:hidden;margin:12px 0 0;background:var(--raised)}progress::-webkit-progress-bar{background:var(--raised)}progress::-webkit-progress-value{background:var(--accent)}progress::-moz-progress-bar{background:var(--accent)}.file.failed progress::-webkit-progress-value{background:var(--danger)}.banner{display:none;margin:0 0 18px;padding:12px 15px;border-radius:12px;background:#392924;color:var(--danger);font-size:13px}.banner.visible{display:block}.footer{font-size:12px;color:var(--muted);margin-top:32px}.host{font-variant-numeric:tabular-nums;overflow-wrap:anywhere}a{color:var(--accent)}
    .capacity,.fileMeta,.queueSummary,.host{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;font-variant-numeric:tabular-nums}
    @media(max-width:760px){.wrap{padding:28px 18px}header{margin-bottom:34px}.logo{font-size:33px}h1{font-size:25px}.columns{grid-template-columns:1fr}.aside{display:none}.drop{min-height:235px}.fileTop{gap:8px}.fileIcon{display:none}.fileActions{margin-left:0}.fileTop{flex-wrap:wrap}.fileState{margin-left:auto}.fileActions{width:100%;justify-content:flex-end;margin-top:4px}.fileName{font-size:14px}}
    @media(prefers-reduced-motion:reduce){*{transition:none!important}}
  </style>
</head>
<body>
  <main class="wrap">
    <header><span class="logo">Prism</span><span class="status offline" id="connection"><span class="dot"></span><span id="connectionLabel">正在连接 iPhone</span></span></header>
    <h1>电脑里的片段，轻松带过来。</h1>
    <p class="lead">选择视频或图片，直接传入手机媒体库。支持批量上传。</p>
    <div id="banner" class="banner" role="status"></div>
    <div class="columns">
      <section>
        <div class="drop" id="drop">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="18" height="12" rx="2"/><path d="M8 21h8m-4-6v6M8 9l4-4 4 4m-4-4v7"/></svg>
          <h2>把视频或图片拖到这里</h2>
          <p>MP4、MOV、MKV、AVI、JPG、PNG、HEIC 等常见格式</p>
          <button type="button" class="primary" id="choose">选择文件</button>
          <input id="picker" type="file" multiple hidden accept="video/*,image/*,.mkv,.avi,.webm,.ts,.mts,.m2ts,.mpg,.mpeg,.wmv,.flv,.3gp,.heic,.heif,.webp,.tiff,.bmp">
        </div>
        <div class="queueHeader"><h2>传输列表</h2><span id="summary" class="queueSummary" aria-live="polite">还没有文件</span></div>
        <p id="empty" class="empty">添加文件后，进度会显示在这里。</p>
        <div id="queue" class="queue"></div>
      </section>
      <aside class="aside">
        <p class="eyebrow">手机可用空间</p><p class="capacity" id="capacity">—</p>
        <h2>传输时，请记住</h2>
        <ol class="steps"><li>电脑和手机连接同一 Wi-Fi。</li><li>保持手机的传文件页面打开。</li><li>完成后，打开手机媒体库查看。</li></ol>
        <p class="note">上传中断时，临时文件会清理。点击重试即可重新上传；同名文件会自动保留为新副本。</p>
      </aside>
    </div>
    <p class="footer">接收设备：<span id="host" class="host"></span><br>请保持手机上的传文件页面打开。切换网络后地址可能变化，以手机显示为准。</p>
  </main>
  <script>
    (() => {
      'use strict';
      const root = location.pathname.endsWith('/') ? location.pathname : location.pathname + '/';
      const $ = id => document.getElementById(id);
      const jobs = [];
      const allowed = new Set('mp4 mov m4v mkv avi webm ts mts m2ts mpg mpeg wmv flv 3gp jpg jpeg png heic heif gif webp tif tiff bmp'.split(' '));
      let active = null;
      let polling = false;
      $('host').textContent = location.host;
      function bytes(value) {
        const number = Number(value);
        if (!Number.isFinite(number) || number < 0) return '—';
        if (number < 1024) return number + ' B';
        const units = ['KB', 'MB', 'GB', 'TB'];
        let amount = number / 1024, index = 0;
        while (amount >= 1024 && index < units.length - 1) { amount /= 1024; index++; }
        return amount.toFixed(amount >= 100 ? 0 : 1) + ' ' + units[index];
      }
      function banner(message) {
        $('banner').textContent = message || '';
        $('banner').classList.toggle('visible', Boolean(message));
      }
      async function status() {
        if (polling) return;
        polling = true;
        try {
          const response = await fetch(root + 'status', { cache: 'no-store', signal: AbortSignal.timeout(8000) });
          const result = await response.json();
          if (!response.ok) throw new Error(result.message || '连接已关闭，请使用手机上的新地址。');
          $('capacity').textContent = bytes(result.freeBytes);
          $('connection').classList.remove('offline');
          $('connectionLabel').textContent = '已连接 iPhone';
          if (!active) banner('');
        } catch (error) {
          $('connection').classList.add('offline');
          $('connectionLabel').textContent = '连接已断开';
          banner(error.message === 'Failed to fetch' ? '无法连接手机。请确认同一 Wi-Fi，并保持手机的传文件页面打开。' : error.message);
        } finally { polling = false; }
      }
      function summary() {
        const done = jobs.filter(job => job.state === 'completed').length;
        const pending = jobs.filter(job => job.state === 'waiting' || job.state === 'uploading').length;
        $('summary').textContent = jobs.length ? done + ' / ' + jobs.length + ' 已完成' + (pending ? ' · ' + pending + ' 个待接收' : '') : '还没有文件';
        $('empty').hidden = jobs.length > 0;
      }
      function render(job) {
        job.row.className = 'file ' + job.state;
        const statusText = { waiting: '等待上传', uploading: '上传中', completed: '已完成', failed: '失败', cancelled: '已取消' };
        job.stateLabel.textContent = statusText[job.state];
        job.progress.value = job.file.size ? job.loaded / job.file.size : 0;
        job.progress.setAttribute('aria-label', job.file.name + ' 上传进度');
        if (job.state === 'completed') {
          job.meta.textContent = bytes(job.file.size) + ' · 已存入 ' + (job.savedAs || job.file.name);
        } else if (job.state === 'failed' || job.state === 'cancelled') {
          job.meta.textContent = job.error || '已取消，可重新上传。';
        } else if (job.state === 'uploading') {
          const percent = Math.min(100, Math.floor(job.loaded / job.file.size * 100));
          job.meta.textContent = bytes(job.loaded) + ' / ' + bytes(job.file.size) + ' · ' + (percent === 100 ? '正在保存…' : percent + '%');
        } else { job.meta.textContent = bytes(job.file.size) + ' · 等待前一个文件完成'; }
        job.retry.hidden = !['failed', 'cancelled'].includes(job.state);
        job.cancel.hidden = !['waiting', 'uploading'].includes(job.state);
        summary();
      }
      function makeJob(file) {
        const job = { file, state: 'waiting', loaded: 0, xhr: null, error: null, savedAs: null };
        job.row = document.createElement('article');
        const top = document.createElement('div'); top.className = 'fileTop';
        const details = document.createElement('div'); details.className = 'fileDetails';
        const name = document.createElement('p'); name.className = 'fileName'; name.textContent = file.name;
        job.meta = document.createElement('p'); job.meta.className = 'fileMeta';
        details.append(name, job.meta);
        job.stateLabel = document.createElement('span'); job.stateLabel.className = 'fileState';
        const actions = document.createElement('div'); actions.className = 'fileActions';
        job.retry = document.createElement('button'); job.retry.type = 'button'; job.retry.className = 'secondary'; job.retry.textContent = '重试';
        job.cancel = document.createElement('button'); job.cancel.type = 'button'; job.cancel.className = 'secondary cancel'; job.cancel.textContent = '取消';
        job.retry.addEventListener('click', () => { job.state = 'waiting'; job.loaded = 0; job.error = null; render(job); drain(); });
        job.cancel.addEventListener('click', () => {
          if (job.xhr) job.xhr.abort();
          else { job.state = 'cancelled'; job.error = '已取消，可重新上传。'; render(job); }
        });
        actions.append(job.retry, job.cancel); top.append(details, job.stateLabel, actions);
        job.progress = document.createElement('progress'); job.progress.max = 1; job.progress.value = 0;
        job.row.append(top, job.progress); $('queue').appendChild(job.row);
        const extension = file.name.split('.').pop().toLowerCase();
        if (!allowed.has(extension)) { job.state = 'failed'; job.error = '暂不支持此类型，请选择视频或图片。'; job.retry.disabled = true; }
        if (file.size === 0) { job.state = 'failed'; job.error = '文件为空，无法上传。'; job.retry.disabled = true; }
        return job;
      }
      function enqueue(files) {
        Array.from(files).forEach(file => { const job = makeJob(file); jobs.push(job); render(job); });
        drain();
      }
      function drain() {
        if (active) return;
        const job = jobs.find(item => item.state === 'waiting');
        if (!job) { status(); return; }
        active = job; job.state = 'uploading'; job.loaded = 0;
        const xhr = new XMLHttpRequest(); job.xhr = xhr;
        xhr.open('POST', root + 'upload?name=' + encodeURIComponent(job.file.name));
        xhr.setRequestHeader('Content-Type', 'application/octet-stream');
        xhr.setRequestHeader('X-Playit-Upload', '1');
        xhr.upload.addEventListener('progress', event => { if (event.lengthComputable) { job.loaded = event.loaded; render(job); } });
        let settled = false;
        function finish(state, message, result) {
          if (settled) return; settled = true;
          job.state = state; job.error = message || null; job.xhr = null;
          if (state === 'completed') { job.loaded = job.file.size; job.savedAs = result && result.filename; }
          active = null; render(job); drain();
        }
        xhr.addEventListener('load', () => {
          let result = {}; try { result = JSON.parse(xhr.responseText); } catch (_) {}
          if (xhr.status === 201) finish('completed', null, result);
          else finish('failed', result.message || '上传失败（' + xhr.status + '），请重试。');
        });
        xhr.addEventListener('error', () => finish('failed', '连接中断，请检查 Wi-Fi 和手机页面后重试。'));
        xhr.addEventListener('abort', () => finish('cancelled', '已取消，手机端的临时文件将清理。'));
        render(job);
        try { xhr.send(job.file); }
        catch (_) { finish('failed', '无法开始上传，请确认浏览器仍可访问手机地址后重试。'); }
      }
      $('choose').addEventListener('click', event => { event.stopPropagation(); $('picker').click(); });
      $('drop').addEventListener('click', event => { if (event.target !== $('choose')) $('picker').click(); });
      $('drop').addEventListener('keydown', event => {
        if (event.target !== $('drop')) return;
        if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); $('picker').click(); }
      });
      $('picker').addEventListener('change', () => { enqueue($('picker').files); $('picker').value = ''; });
      document.addEventListener('dragover', event => event.preventDefault());
      document.addEventListener('drop', event => event.preventDefault());
      $('drop').addEventListener('dragover', event => { event.preventDefault(); $('drop').classList.add('dragging'); });
      $('drop').addEventListener('dragleave', () => $('drop').classList.remove('dragging'));
      $('drop').addEventListener('drop', event => { event.preventDefault(); $('drop').classList.remove('dragging'); enqueue(event.dataTransfer.files); });
      window.addEventListener('beforeunload', event => { if (active) { event.preventDefault(); event.returnValue = ''; } });
      status(); setInterval(status, 10000);
    })();
  </script>
</body>
</html>
"""#
}
