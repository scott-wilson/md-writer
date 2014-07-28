{$, View, EditorView} = require "atom"
utils = require "./utils"
CSON = require "season"
path = require "path"
fs = require "fs-plus"

module.exports =
class AddLinkView extends View
  editor: null
  posts: null
  links: null
  referenceId: false
  previouslyFocusedElement: null

  @content: ->
    @div class: "md-writer md-writer-dialog overlay from-top", =>
      @label "Create Link", class: "icon icon-link"
      @div =>
        @label "Text to be displayed", class: "message"
        @subview "textEditor", new EditorView(mini: true)
        @label "Web Address", class: "message"
        @subview "urlEditor", new EditorView(mini: true)
        @label "Title", class: "message"
        @subview "titleEditor", new EditorView(mini: true)
      @p =>
        @input type: "checkbox", outlet: "saveCheckbox"
        @span "Automatically link to this text next time", class: "cb-label"
      @div outlet: "searchBox", =>
        @label "Search Posts", class: "icon icon-search"
        @subview "searchEditor", new EditorView(mini: true)
        @ul class: "md-writer-list", outlet: "searchResult"

  initialize: ->
    @fetchPosts()
    @loadSavedLinks()
    @handleEvents()
    @on "core:confirm", => @onConfirm()
    @on "core:cancel", => @detach()

  handleEvents: ->
    @searchEditor.hiddenInput.on "keyup", => @updateSearch()
    @searchResult.on "click", "li", (e) => @useSearchResult(e)

  onConfirm: ->
    text = @textEditor.getText()
    url = @urlEditor.getText().trim()
    title = @titleEditor.getText().trim()
    if url then @insertLink(text, title, url) else @removeLink(text)
    @updateSavedLink(text, title, url)
    @detach()

  display: ->
    @previouslyFocusedElement = $(':focus')
    @editor = atom.workspace.getActiveEditor()
    @setLinkFromSelection()
    atom.workspaceView.append(this)
    @searchBox.hide()
    if @textEditor.getText()
      @urlEditor.getEditor().selectAll()
      @urlEditor.focus()
    else
      @textEditor.focus()

  detach: ->
    return unless @hasParent()
    @previouslyFocusedElement?.focus()
    super

  setLinkFromSelection: ->
    selection = @editor.getSelectedText()
    return unless selection

    if utils.isInlineLink(selection)
      link = utils.parseInlineLink(selection)
      @setLink(link.text, link.url, link.title)
      @saveCheckbox.prop("checked", true) unless @isChangedSavedLink(link)
    else if utils.isReferenceLink(selection)
      link = utils.parseReferenceLink(selection, @editor.getText())
      @referenceId = link.id
      @setLink(link.text, link.url, link.title)
      @saveCheckbox.prop("checked", true) unless @isChangedSavedLink(link)
    else if @getSavedLink(selection)
      link = @getSavedLink(selection)
      @setLink(selection, link.url, link.title)
      @saveCheckbox.prop("checked", true)
    else
      @setLink(selection, "", "")

  updateSearch: ->
    return unless @posts
    query = @searchEditor.getText().trim()
    results = @posts.filter (post) -> query and post.title.contains(query)
    results = results.map (post) ->
      "<li data-url='#{post.url}'>#{post.title}</li>"
    @searchResult.empty().append(results.join(""))

  useSearchResult: (e) ->
    @titleEditor.setText(e.target.textContent)
    @urlEditor.setText(e.target.dataset.url)

  insertLink: (text, title, url) ->
    if @referenceId
      @updateReferenceLink(text, title, url)
    else if title
      @insertReferenceLink(text, title, url)
    else
      @editor.insertText("[#{text}](#{url})")

  removeLink: (text) ->
    if @referenceId
      @removeReferenceLink(text)
    else
      @editor.insertText(text)

  insertReferenceLink: (text, title, url) ->
    @editor.buffer.beginTransaction()

    # modify selection
    id = require("guid").raw()[0..7]
    @editor.insertText("[#{text}][#{id}]")

    # insert reference
    position = @editor.getCursorBufferPosition()
    @editor.insertNewlineBelow()
    @editor.moveCursorDown()
    @editor.insertText("[#{id}]: #{url} \"#{title}\"")
    @editor.moveCursorDown()
    line = @editor.selectLine()[0].getText().trim()
    unless utils.isReferenceDefinition(line)
      @editor.moveCursorUp()
      @editor.insertNewlineBelow()
    @editor.setCursorBufferPosition(position)

    @editor.buffer.commitTransaction()

  updateReferenceLink: (text, title, url) ->
    if title
      @editor.buffer.beginTransaction()
      position = @editor.getCursorBufferPosition()
      @editor.buffer.scan /// ^ \[#{@referenceId}\]: \ + ///, (match) =>
        @editor.setSelectedBufferRange(match.range)
        @editor.insertText("[#{id}]: #{url} \"#{title}\"")
      @editor.setCursorBufferPosition(position)
      @editor.buffer.commitTransaction()
    else
      @removeReferenceLink("[#{text}](#{url})")

  removeReferenceLink: (text) ->
    @editor.buffer.beginTransaction()
    @editor.insertText(text)
    position = @editor.getCursorBufferPosition()
    @editor.buffer.scan /// ^ \[#{@referenceId}\]: \ + ///, (match) =>
      @editor.setSelectedBufferRange(match.range)
      @editor.deleteLine()
      @editor.deleteLine() unless @editor.selectToEndOfLine()[0].getText()
    @editor.setCursorBufferPosition(position)
    @editor.buffer.commitTransaction()

  setLink: (text, url, title) ->
    @textEditor.setText(text)
    @urlEditor.setText(url)
    @titleEditor.setText(title)

  getSavedLink: (text) ->
    @links?[text.toLowerCase()]

  isChangedSavedLink: (link) ->
    savedLink = @getSavedLink(link.text)
    savedLink and (savedLink.title != link.title or savedLink.url != link.url)

  updateSavedLink: (text, title, url) ->
    try
      if @saveCheckbox.prop("checked")
        @links[text.toLowerCase()] = title: title, url: url if url
      else if not @isChangedSavedLink(text: text, title: title, url: url)
        delete @links[text.toLowerCase()]
      CSON.writeFileSync(@getSavedLinksPath(), @links)
    catch error
      console.log(error.message)

  loadSavedLinks: ->
    try
      file = @getSavedLinksPath()
      if fs.existsSync(file)
        @links = CSON.readFileSync(file)
      else
        @links = {}
    catch error
      console.log(error.message)

  getSavedLinksPath: ->
    atom.project.resolve(atom.config.get("md-writer.siteLinkPath"))

  fetchPosts: ->
    uri = atom.config.get("md-writer.urlForPosts")
    succeed = (body) =>
      @searchBox.show()
      @posts = body.posts
    error = (err) => @searchBox.hide()
    utils.getJSON(uri, succeed, error)
