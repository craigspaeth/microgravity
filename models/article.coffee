_ = require 'underscore'
_s = require 'underscore.string'
Q = require 'bluebird-q'
sd = require('sharify').data
moment = require 'moment'
Backbone = require 'backbone'
Artworks = require '../collections/artworks.coffee'
Section = require './section.coffee'
Partner = require './partner.coffee'
Fair = require './fair.coffee'
{ crop, resize } = require '../components/resizer/index.coffee'
{ compactObject } = require './mixins/compact_object.coffee'

module.exports = class Article extends Backbone.Model

  defaults:
    sections: []

  urlRoot: "#{sd.POSITRON_URL}/api/articles"

  href: ->
    "/article/#{@get('slug')}"

  fullHref: ->
    "#{sd.ARTSY_URL}/article/#{@get('slug')}"

  date: (attr = 'published_at') ->
    moment @get(attr)

  formatDate: ->
    @date('published_at').format('MMMM Do')

  related: ->
    return @__related__ if @__related__?
    @__related__ =
      author: new Backbone.Model(@get 'author')

  cropUrlFor: (attr, args...) ->
    crop @get(attr), args...

  authorHref: ->
    if @get('author') then "/#{@get('author').profile_handle}" else @href()

  shareDescription: ->
    (@get('share_description') or @get('thumbnail_title')) + " @artsy"

  isFairArticle: ->
    # associated to a fair and the Fairs team has written it
    @get('fair_ids')?.length and @get('channel_id') is sd.FAIR_CHANNEL_ID

  fetchRelated: (options) ->
    Articles = require '../collections/articles.coffee'
    dfds = []
    relatedArticles = new Articles()
    calloutArticles = new Articles()
    superArticle = false
    if @get('section_ids')?.length
      dfds.push (section = new Section(id: @get('section_ids')[0])).fetch(cache: true)
      dfds.push (sectionArticles = new Articles).fetch
        cache: true
        data: section_id: @get('section_ids')[0], published: true
    else
      channel_id = @get('channel_id') or @get('partner_channel_id') or sd.ARTSY_EDITORIAL_ID
      dfds.push (footerArticles = new Articles).fetch
        cache: true
        data:
          published: true
          sort: '-published_at'
          channel_id: channel_id

    # Check if the article is a super article
    if @get('is_super_article')
      superArticle = this
    else
       # Check if the article is IN a super article
      dfds.push (foo = new Articles()).fetch
        cache: true
        data:
          super_article_for: @get('id')
          published: true
        success: (articles) ->
          superArticle = articles?.models[0]

    # Get callout articles
    if @get('sections')?.length
      for sec in @get('sections') when sec.type is 'callout'
        if sec.article
          dfds.push new Article(id: sec.article).fetch
            cache: true
            success: (article) ->
              calloutArticles.add(article)

    if @get('partner_channel_id')
      dfds.push (partner = new Partner(id: @get('partner_channel_id'))).fetch(cache: true)

    Q.allSettled(dfds).then =>
      superArticleDefferreds = if superArticle then superArticle.fetchRelatedArticles(relatedArticles) else []
      Q.allSettled(superArticleDefferreds).then =>
        relatedArticles.orderByIds(superArticle.get('super_article').related_articles) if superArticle and relatedArticles?.length
        footerArticles.remove @ if footerArticles
        sectionArticles.remove @ if sectionArticles
        @set('section', section) if section
        options.success(
          article: this
          footerArticles: footerArticles
          section: section
          sectionArticles: sectionArticles
          superArticle: superArticle
          relatedArticles: relatedArticles
          calloutArticles: calloutArticles
          partner: partner if partner
        )

  fetchProfiles: (options) ->
    dfds = []
    if @get('partner_channel_id')
      dfds.push (partner = new Partner(id: @get('partner_channel_id'))).fetch(cache: true)

    else if @isFairArticle()
      dfds.push (fair = new Fair(id: @get('fair_ids')[0])).fetch(cache: true)

    Q.allSettled(dfds).then =>
      options.success
        fair: fair
        partner: partner

  #
  # Super Article helpers
  fetchRelatedArticles: (relatedArticles) ->
    for id in @get('super_article').related_articles
      new Article(id: id).fetch
        cache: true
        success: (article) =>
          relatedArticles.add article

  toJSONLD: ->
    creator = []
    creator.push @get('author').name if @get('author')
    creator = _.union(creator, _.pluck(@get('contributing_authors'), 'name')) if @get('contributing_authors').length
    compactObject {
      "@context": "http://schema.org"
      "@type": "NewsArticle"
      "headline": @get('thumbnail_title')
      "url": "#{sd.FORCE_URL}" + @href()
      "thumbnailUrl": @get('thumbnail_image')
      "dateCreated": @get('published_at')
      "articleSection": if @get('section') then @get('section').get('title') else "Editorial"
      "creator": creator
      "keywords": @get('tags') if @get('tags').length
    }
