Partition magic
===============

Partition magic - скрипт-сниппет для Postgresql на plpgsql, позволяющий лёгко, быстро и просто создавать партицированные таблицы в вашем проекте, а также изменять, добавлять и удалять данные.

Без единой правки кода вашего приложения - вы можете "разбить" данные на партиции.

Как начать?
===========

1. Запустите данный скрипт в ваш Postgresql ```_2gis_partition_magic.sql``` - произойдёт установка
2. Создайте базовую таблицу, которую вы собираетесь разбить на партиции, например:
```
CREATE SEQUENCE "news_id_seq" START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;

CREATE TABLE news (
	  id BIGINT DEFAULT nextval('news_id_seq'::regclass),
	  category_id INT,
	  title TEXT,
	  data TEXT
	);
	ALTER TABLE ONLY "news" ADD CONSTRAINT "pk_news" PRIMARY KEY ("id");
```
3. Из примера выше - мы будем партицировать таблицу новостей (news) по полю category_id
```
_2gis_partition_magic('news', 'category_id');
```
4. ....
5. PROFIT - это действительно так просто

Как пользоваться?
=================
Пример можно посмотреть в файле ```_2gis_partition_magic_test.sql```, а также вот краткий экскурс:

```
INSERT INTO news(category_id, title) VALUES (1, 'Item 1') RETURNING *;
INSERT INTO news(category_id, title) VALUES (2, 'Item 2') RETURNING *;
INSERT INTO news(category_id, title) VALUES (3, 'Item 3') RETURNING *;
INSERT INTO news(category_id, title) VALUES (4, 'Item 4') RETURNING *;
INSERT INTO news(category_id, title)
VALUES
(1, 'Item 5'),
(1, 'Item 6'),
(2, 'Item 7'),
(2, 'Item 8'),
(3, 'Item 9'),
(3, 'Item 10')
RETURNING *;
```

Данные автоматически попадут в нужные партиции, а если партиция еще не существовала - она будет создана автоматически. Можно проверить:
```
SELECT COUNT(*) FROM news;
SELECT COUNT(*) FROM news_1;
SELECT COUNT(*) FROM news_2;
SELECT COUNT(*) FROM news_3;
SELECT COUNT(*) FROM news_4;
```

А также, в основной таблице ничего нет:
```
SELECT * FROM ONLY test_table;
```

*Домашнее задание*: попробуйте UPDATE и DELETE

Что важно помнить?
==================
Накатывайте изменения структуры только на основную таблице, после чего запускайте 
```
_2gis_partition_magic('news', 'category_id');
```
Таблицы будут обновлены автоматически.

Что еще важно помнить?
==================

Сам по себе partition magic не даёт ускорения при работе с таблицами. Вы можете не изменять ваш код, а работать также с основной таблицей, если вы пишите запросы такого вида:
```
SELECT * FROM news ...;
UPDATE news ...;
DELETE FROM news ...;
```

Будет происходить поиск по всем партициям, чтобы получить буст, выберите один из 2х вариантов:
1. Укажите ваш constraint (в примере выше - category_id) в WHERE-условии, например:
```
SELECT * FROM news WHERE category_id = 1;
UPDATE news WHERE category_id = 1;
DELETE FROM news WHERE category_id = 1;
```
или так:
```
SELECT * FROM news WHERE category_id = 1 OR category_id = 2;
UPDATE news WHERE category_id = 1 OR category_id = 2;
DELETE FROM news WHERE category_id = 1 OR category_id = 2;
```
или так:
```
SELECT * FROM news WHERE category_id IN (1, 2);
UPDATE news WHERE category_id IN (1, 2);
DELETE FROM news WHERE category_id IN (1, 2);
```
2. Укажите партицию, с которой вы работаете:
```
SELECT * FROM news_1 ...;
UPDATE news_2 ...;
DELETE FROM news_3 ...;
```
