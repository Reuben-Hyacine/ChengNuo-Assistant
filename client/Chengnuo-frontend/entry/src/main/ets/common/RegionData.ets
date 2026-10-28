/**
 * 省市数据（个人空间「地区」两级分叉树用）：
 * 34 个省级行政区（含港澳台）；直辖市统一选「市辖区」；城市用「、」拼接由构造器拆分。
 */
export class RegionProvince {
  readonly name: string;
  readonly cities: string[];

  constructor(name: string, citiesJoined: string) {
    this.name = name;
    const list: string[] = [];
    const parts: string[] = citiesJoined.split('、');
    for (let i = 0; i < parts.length; i++) {
      const city: string = parts[i].trim();
      if (city.length > 0) {
        list.push(city);
      }
    }
    this.cities = list;
  }
}

export const REGION_PROVINCES: RegionProvince[] = [
  new RegionProvince('北京市', '市辖区'),
  new RegionProvince('上海市', '市辖区'),
  new RegionProvince('天津市', '市辖区'),
  new RegionProvince('重庆市', '市辖区'),
  new RegionProvince('河北省', '石家庄、唐山、秦皇岛、邯郸、邢台、保定、张家口、承德、沧州、廊坊、衡水'),
  new RegionProvince('山西省', '太原、大同、阳泉、长治、晋城、朔州、晋中、运城、忻州、临汾、吕梁'),
  new RegionProvince('辽宁省', '沈阳、大连、鞍山、抚顺、本溪、丹东、锦州、营口、阜新、辽阳、盘锦、铁岭、朝阳、葫芦岛'),
  new RegionProvince('吉林省', '长春、吉林、四平、辽源、通化、白山、松原、白城、延边'),
  new RegionProvince('黑龙江省', '哈尔滨、齐齐哈尔、鸡西、鹤岗、双鸭山、大庆、伊春、佳木斯、七台河、牡丹江、黑河、绥化、大兴安岭'),
  new RegionProvince('江苏省', '南京、无锡、徐州、常州、苏州、南通、连云港、淮安、盐城、扬州、镇江、泰州、宿迁'),
  new RegionProvince('浙江省', '杭州、宁波、温州、嘉兴、湖州、绍兴、金华、衢州、舟山、台州、丽水'),
  new RegionProvince('安徽省', '合肥、芜湖、蚌埠、淮南、马鞍山、淮北、铜陵、安庆、黄山、滁州、阜阳、宿州、六安、亳州、池州、宣城'),
  new RegionProvince('福建省', '福州、厦门、莆田、三明、泉州、漳州、南平、龙岩、宁德'),
  new RegionProvince('江西省', '南昌、景德镇、萍乡、九江、新余、鹰潭、赣州、吉安、宜春、抚州、上饶'),
  new RegionProvince('山东省', '济南、青岛、淄博、枣庄、东营、烟台、潍坊、济宁、泰安、威海、日照、临沂、德州、聊城、滨州、菏泽'),
  new RegionProvince('河南省', '郑州、开封、洛阳、平顶山、安阳、鹤壁、新乡、焦作、濮阳、许昌、漯河、三门峡、南阳、商丘、信阳、周口、驻马店'),
  new RegionProvince('湖北省', '武汉、黄石、十堰、宜昌、襄阳、鄂州、孝感、荆州、黄冈、咸宁、随州、恩施'),
  new RegionProvince('湖南省', '长沙、株洲、湘潭、衡阳、邵阳、岳阳、常德、张家界、益阳、郴州、永州、怀化、娄底、湘西'),
  new RegionProvince('广东省', '广州、韶关、深圳、珠海、汕头、佛山、江门、湛江、茂名、肇庆、惠州、梅州、汕尾、河源、阳江、清远、东莞、中山、潮州、揭阳、云浮'),
  new RegionProvince('海南省', '海口、三亚、三沙、儋州'),
  new RegionProvince('四川省', '成都、自贡、攀枝花、泸州、德阳、绵阳、广元、遂宁、内江、乐山、南充、眉山、宜宾、广安、达州、雅安、巴中、资阳、阿坝、甘孜、凉山'),
  new RegionProvince('贵州省', '贵阳、六盘水、遵义、安顺、毕节、铜仁、黔西南、黔东南、黔南'),
  new RegionProvince('云南省', '昆明、曲靖、玉溪、保山、昭通、丽江、普洱、临沧、楚雄、红河、文山、西双版纳、大理、德宏、怒江、迪庆'),
  new RegionProvince('陕西省', '西安、铜川、宝鸡、咸阳、渭南、延安、汉中、榆林、安康、商洛'),
  new RegionProvince('甘肃省', '兰州、嘉峪关、金昌、白银、天水、武威、张掖、平凉、酒泉、庆阳、定西、陇南、临夏、甘南'),
  new RegionProvince('青海省', '西宁、海东、海北、黄南、海南州、果洛、玉树、海西'),
  new RegionProvince('台湾省', '台北、新北、桃园、台中、台南、高雄、基隆、新竹、嘉义'),
  new RegionProvince('内蒙古自治区', '呼和浩特、包头、乌海、赤峰、通辽、鄂尔多斯、呼伦贝尔、巴彦淖尔、乌兰察布、兴安盟、锡林郭勒、阿拉善'),
  new RegionProvince('广西壮族自治区', '南宁、柳州、桂林、梧州、北海、防城港、钦州、贵港、玉林、百色、贺州、河池、来宾、崇左'),
  new RegionProvince('西藏自治区', '拉萨、日喀则、昌都、林芝、山南、那曲、阿里'),
  new RegionProvince('宁夏回族自治区', '银川、石嘴山、吴忠、固原、中卫'),
  new RegionProvince('新疆维吾尔自治区', '乌鲁木齐、克拉玛依、吐鲁番、哈密、昌吉、博尔塔拉、巴音郭楞、阿克苏、克孜勒苏、喀什、和田、伊犁、塔城、阿勒泰'),
  new RegionProvince('香港特别行政区', '香港岛、九龙、新界'),
  new RegionProvince('澳门特别行政区', '澳门半岛、氹仔、路环')
];

/** 省级名称列表（选择器数据源） */
export function regionProvinceNames(): string[] {
  const names: string[] = [];
  for (let i = 0; i < REGION_PROVINCES.length; i++) {
    names.push(REGION_PROVINCES[i].name);
  }
  return names;
}

/** 按省级名称找省份（找不到返回 null） */
export function regionProvinceOf(name: string): RegionProvince | null {
  for (let i = 0; i < REGION_PROVINCES.length; i++) {
    if (REGION_PROVINCES[i].name === name) {
      return REGION_PROVINCES[i];
    }
  }
  return null;
}
