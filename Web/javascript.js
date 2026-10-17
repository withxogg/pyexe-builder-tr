(function () {
  var $ = function (s) { return document.querySelector(s); };
  var $$ = function (s) { return Array.prototype.slice.call(document.querySelectorAll(s)); };

  // Mobil içindekiler menüsü
  $('#menuBtn').addEventListener('click', function () { document.body.classList.toggle('nav-open'); });
  $$('#toc a').forEach(function (a) {
    a.addEventListener('click', function () { document.body.classList.remove('nav-open'); });
  });

  // Okunan bölümü içindekilerde işaretle
  var links = {};
  $$('#toc a').forEach(function (a) { links[a.getAttribute('href').slice(1)] = a; });
  if ('IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        Object.keys(links).forEach(function (k) { links[k].removeAttribute('aria-current'); });
        if (links[e.target.id]) links[e.target.id].setAttribute('aria-current', 'true');
      });
    }, { rootMargin: '-15% 0px -75% 0px' });
    $$('main section[id]').forEach(function (s) { io.observe(s); });
  }

  // Proje türüne göre biçim önerisi
  var PICKS = {
    gui:   ['Tek dosya, konsolsuz', 'Pencereli programda siyah konsol penceresi istemezsiniz; tek .exe paylaşmayı da kolaylaştırır.'],
    cli:   ['Tek dosya, konsol açık', 'Çıktıyı ve girdiyi konsolda görmeniz gerekir. Sık kullanılıyorsa “klasör, konsol açık” daha hızlı açılır.'],
    bot:   ['Tek dosya, konsol açık', 'Bot veya sunucunun günlüğünü ve hata mesajlarını canlı izleyebilirsiniz.'],
    game:  ['Klasör, konsolsuz', 'Oyunlar çok görsel ve ses dosyası içerir; klasör biçimi daha hızlı açılır ve konsol görünmez.'],
    share: ['Tek dosya', 'Tek bir .exe göndermek en kolay yoldur. Programınız pencereliyse konsolsuz, değilse konsol açık seçin.']
  };
  $('#kind').addEventListener('change', function () {
    var p = PICKS[this.value], out = $('#pick');
    out.textContent = '';
    if (!p) { out.textContent = 'Proje türünü seçince önerilen biçim burada görünür.'; return; }
    var b = document.createElement('strong');
    b.textContent = 'Önerilen: ' + p[0] + '. ';
    out.appendChild(b);
    out.appendChild(document.createTextNode(p[1]));
  });

  // SSS arama
  $('#faqSearch').addEventListener('input', function () {
    var q = this.value.toLocaleLowerCase('tr').trim(), shown = 0;
    $$('#sss details').forEach(function (d) {
      var hit = !q || d.textContent.toLocaleLowerCase('tr').indexOf(q) !== -1;
      d.hidden = !hit;
      if (hit) shown++;
    });
    $('#faqEmpty').hidden = shown > 0;
  });
})();
