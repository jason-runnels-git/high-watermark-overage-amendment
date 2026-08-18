import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import getQuoteContext from '@salesforce/apex/AmendQuoteEndDateController.getQuoteContext';
import patchEndDate from '@salesforce/apex/AmendQuoteEndDateController.patchEndDate';
import fixQuoteAction from '@salesforce/apex/AmendQuoteEndDateController.fixQuoteAction';
import getCalculationStatus from '@salesforce/apex/AmendQuoteEndDateController.getCalculationStatus';

export default class AmendQuoteEndDate extends LightningElement {
    @api recordId;

    @track isOpen = false;
    @track isLoading = false;
    @track isPatching = false;
    @track patchStatus = '';
    @track errorMessage = null;

    @track quoteContext = null;
    @track newEndDate = null;

    _sessionId = null;

    // ─── Session token ─────────────────────────────────────────────────────────

    connectedCallback() {
        window.addEventListener('message', this._handleMessage.bind(this));
    }

    disconnectedCallback() {
        window.removeEventListener('message', this._handleMessage.bind(this));
    }

    _handleMessage(event) {
        if (event.data?.sessionId) this._sessionId = event.data.sessionId;
    }

    handleIframeLoad() {}

    // ─── Button entry point ────────────────────────────────────────────────────

    async handleOpenModal() {
        this.isOpen = true;
        this.isLoading = true;
        this.errorMessage = null;
        this.newEndDate = null;
        this.patchStatus = '';
        this.isPatching = false;

        try {
            this.quoteContext = await getQuoteContext({ quoteId: this.recordId });
            this.newEndDate = this.quoteContext.endDate;
        } catch (err) {
            this.errorMessage = 'Failed to load quote: ' + (err.body?.message || err.message);
        }
        this.isLoading = false;
    }

    handleClose() {
        this.isOpen = false;
    }

    // ─── Getters ───────────────────────────────────────────────────────────────

    get isSaveDisabled() {
        return this.isPatching || !this.newEndDate || this.newEndDate === this.quoteContext?.endDate;
    }

    get saveLabel() {
        return this.isPatching ? 'Saving...' : 'Save End Date';
    }

    get currentEndDateDisplay() {
        return this.quoteContext?.endDate || '—';
    }

    get currentStartDateDisplay() {
        return this.quoteContext?.startDate || '—';
    }

    get lineCount() {
        return (this.quoteContext?.lines || []).length;
    }

    get newTermMonths() {
        if (!this.newEndDate) return null;
        // Use asset lifecycle end date as the delta base (term extension months),
        // falling back to quote start date if unavailable.
        const baseStr = this.quoteContext?.assetEndDate || this.quoteContext?.startDate;
        if (!baseStr) return null;
        const base = new Date(baseStr + 'T00:00:00');
        const end  = new Date(this.newEndDate + 'T00:00:00');
        if (end <= base) return null;
        let total = (end.getFullYear() - base.getFullYear()) * 12
                  + (end.getMonth() - base.getMonth());
        if (end.getDate() < base.getDate()) total += 1;
        return Math.max(1, total);
    }

    get showTermPreview() {
        return this.newEndDate && this.newEndDate !== this.quoteContext?.endDate && this.newTermMonths;
    }

    // ─── User input ────────────────────────────────────────────────────────────

    handleDateChange(event) {
        this.newEndDate = event.detail.value;
        this.errorMessage = null;
    }

    // ─── Save ──────────────────────────────────────────────────────────────────

    async handleSave() {
        if (!this._sessionId) {
            this.errorMessage = 'Session token not ready — wait a moment and try again.';
            return;
        }
        const end   = new Date(this.newEndDate + 'T00:00:00');
        const start = new Date(this.quoteContext.startDate + 'T00:00:00');
        if (end <= start) {
            this.errorMessage = 'End Date must be after the quote Start Date (' + this.quoteContext.startDate + ').';
            return;
        }

        this.isPatching = true;
        this.errorMessage = null;

        try {
            // Step 1: PST PATCH — write EndDate + SubscriptionTerm, trigger pricing
            this.patchStatus = 'Patching End Date and triggering pricing...';
            const patchResult = await patchEndDate({
                sessionId:  this._sessionId,
                quoteId:    this.recordId,
                newEndDate: this.newEndDate
            });
            const patchParsed = JSON.parse(patchResult);
            if (!patchParsed.ok) {
                this.errorMessage = 'PST patch failed: ' + (patchParsed.body || patchParsed.message || JSON.stringify(patchParsed));
                this.isPatching = false;
                this.patchStatus = '';
                return;
            }

            // Step 2: Fix QuoteAction — delete No Change, re-insert Amend.
            // Must happen after PST PATCH, same as overage amendment flow.
            this.patchStatus = 'Fixing QuoteAction...';
            const fixResult = await fixQuoteAction({ quoteId: this.recordId });
            const fixParsed = JSON.parse(fixResult);
            if (!fixParsed.ok) {
                this.errorMessage = 'QuoteAction fix failed: ' + (fixParsed.message || '');
                this.isPatching = false;
                this.patchStatus = '';
                return;
            }

            // Step 3: Poll CalculationStatus
            this.patchStatus = 'Waiting for pricing to complete...';
            const MAX_POLLS = 20;
            for (let i = 0; i < MAX_POLLS; i++) {
                const s = await getCalculationStatus({ quoteId: this.recordId });
                if (s === 'CompletedWithErrors') {
                    this.errorMessage = 'Pricing completed with errors — check the quote pricing panel for details.';
                    this.isPatching = false;
                    this.patchStatus = '';
                    return;
                }
                if (['Completed', 'CompletedWithPricing', 'CompletedWithTax'].includes(s)) break;
                if (i === MAX_POLLS - 1) {
                    this.errorMessage = 'Pricing did not complete in time (status: ' + s + '). Refresh the quote to check.';
                    this.isPatching = false;
                    this.patchStatus = '';
                    return;
                }
                await new Promise(r => setTimeout(r, 2000));
            }

            this.isPatching = false;
            this.isOpen = false;
            this.patchStatus = '';

            this.dispatchEvent(new ShowToastEvent({
                title: 'End Date Updated',
                message: 'Quote end date updated to ' + this.newEndDate
                       + ' (' + patchParsed.newTermMonths + ' months). Pricing recalculated.',
                variant: 'success'
            }));

            this.dispatchEvent(new RefreshEvent());

        } catch (err) {
            this.errorMessage = 'Error: ' + (err.body?.message || err.message);
            this.isPatching = false;
            this.patchStatus = '';
        }
    }
}
