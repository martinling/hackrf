name: Question  
description: Ask a question not covered by current hackrf.rtfd.io documentation 
title: "[Question]: "
labels: ["question"]
body:
  - type: markdown
    attributes:
      value: |
        Thank you for taking the time to ask your question! If you need technical support, want to open a feature request, or need to file a bug report, please abandon this issue, open a new issue, and choose the correct template. If you do not choose the correct template, you will be asked to re-open your issue with the correct template. 
  - type: textarea
    id: question
    attributes:
      label: What would you like to know?
    validations:
      required: true